@preconcurrency import AVFoundation
import Combine
import CoreImage
import CoreMotion
import ImageIO
import UIKit
import Vision

@MainActor
final class CameraController: NSObject, ObservableObject {
    enum PermissionState: Equatable {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var isRunning = false
    @Published private(set) var lastCapturedImage: UIImage?
    @Published private(set) var lastSavedPhotoURL: URL?
    @Published private(set) var photoSaveMessage: String?
    @Published private(set) var nightModeState: NightModeState = .unavailable
    @Published var isNightModeEnabledByUser = true
    @Published var lensFacing: LensFacing = .back
    @Published var zoomLevel: Double = 1.0
    @Published var flashMode = "off"

    var flashEnabled: Bool { flashMode != "off" }

    let session = AVCaptureSession()
    let boomerangCaptureManager = BoomerangCaptureManager()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let portraitPhotoProcessor = PortraitPhotoProcessor()
    private var isPhotoOutputPrepared = false
    private var currentInput: AVCaptureDeviceInput?
    private var pendingPhotoDelegates: [Int64: NSObject] = [:]
    private var activeExposureIndex = 0
    private let photoSaving: any PhotoSaving
    private let nightModeMotionMonitor = NightModeMotionMonitor()
    private var nightModeMonitorTask: Task<Void, Never>?
    private var didPrewarmPhotoStorage = false

    override convenience init() {
        self.init(photoSaving: PhotoLibrarySavingService())
    }

    init(photoSaving: any PhotoSaving) {
        self.photoSaving = photoSaving
        super.init()
        permissionState = Self.currentPermissionState()
    }

    func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
            configureAndStart()
            prewarmPhotoStorageIfNeeded()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
            if granted {
                configureAndStart()
                prewarmPhotoStorageIfNeeded()
            }
        default:
            permissionState = .denied
        }
    }

    func prepareForPhotoCapture(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
            guard granted else { return false }
        default:
            permissionState = .denied
            return false
        }

        self.lensFacing = lensFacing
        self.zoomLevel = CameraBackDeviceSelection.effectiveZoomLevel(lensFacing: lensFacing, requestedZoomLevel: zoomLevel)
        self.flashMode = flashMode.safeCameraFlashMode
        return await configureAndStartForPhotoCapture()
    }

    func prepareForBoomerangCapture(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
            guard granted else { return false }
        default:
            permissionState = .denied
            return false
        }

        self.lensFacing = lensFacing
        self.zoomLevel = CameraBackDeviceSelection.effectiveZoomLevel(lensFacing: lensFacing, requestedZoomLevel: zoomLevel)
        self.flashMode = flashMode.safeCameraFlashMode
        return await configureAndStartForBoomerangCapture()
    }

    func stop() {
        stopNightModeMonitoring()
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    func stopAndWait() async {
        stopNightModeMonitoring()
        let session = session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
                Task { @MainActor in self.isRunning = false }
                continuation.resume()
            }
        }
    }

    func stopAndReleaseCamera() async {
        stopNightModeMonitoring()
        let session = session
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                if let currentInput = self.currentInput {
                    session.removeInput(currentInput)
                    self.currentInput = nil
                }
                session.commitConfiguration()
                Task { @MainActor in self.isRunning = false }
                continuation.resume()
            }
        }
    }

    func apply(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) {
        let clampedZoom = CameraBackDeviceSelection.effectiveZoomLevel(lensFacing: lensFacing, requestedZoomLevel: zoomLevel)
        let shouldSwitchLens = self.lensFacing != lensFacing
        let shouldSwitchZoomLens = !isUsingPreferredDevice(lensFacing: lensFacing, zoomLevel: clampedZoom)
        self.lensFacing = lensFacing
        self.zoomLevel = clampedZoom
        self.flashMode = flashMode.safeCameraFlashMode
        shouldSwitchLens || shouldSwitchZoomLens ? configureAndStart() : applyZoom(clampedZoom)
    }

    func applyExposureIndex(_ exposureIndex: Int) {
        let clampedIndex = min(8, max(-8, exposureIndex))
        activeExposureIndex = clampedIndex
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyExposureOnQueue(clampedIndex, device: device)
        }
    }

    func switchLens() {
        nightModeState = .unavailable
        apply(lensFacing: lensFacing == .back ? .front : .back, zoomLevel: zoomLevel, flashMode: flashMode)
    }

    func startBoomerangCapture() {
        boomerangCaptureManager.startCapture(lensFacing: lensFacing)
    }

    func cancelBoomerangCapture() {
        boomerangCaptureManager.cancel()
    }

    private func prewarmPhotoStorageIfNeeded() {
        guard !didPrewarmPhotoStorage else { return }
        didPrewarmPhotoStorage = true
        Task { [photoSaving] in
            await photoSaving.prewarm()
        }
    }

    private nonisolated static func configurePhotoOutputForSpeed(_ photoOutput: AVCapturePhotoOutput) {
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = false
        }
        if photoOutput.isPortraitEffectsMatteDeliverySupported {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        }
        if #available(iOS 17.0, *) {
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = true
            }
        }
    }

    private nonisolated static func configurePortraitPhotoSettings(_ settings: AVCapturePhotoSettings, output: AVCapturePhotoOutput, enabled: Bool) {
        guard enabled else { return }
        if output.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = false
        }
        if output.isPortraitEffectsMatteDeliveryEnabled {
            settings.isPortraitEffectsMatteDeliveryEnabled = true
            settings.embedsPortraitEffectsMatteInPhoto = false
        }
    }

    private nonisolated static func preparePhotoOutput(_ photoOutput: AVCapturePhotoOutput, completion: @escaping () -> Void = {}) {
        let supportedFlashModes = photoOutput.supportedFlashModes
        let preparedSettings = [AVCaptureDevice.FlashMode.off, .auto, .on].compactMap { flashMode -> AVCapturePhotoSettings? in
            guard supportedFlashModes.contains(flashMode) else { return nil }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            settings.flashMode = flashMode
            return settings
        }
        let fallbackSettings = AVCapturePhotoSettings()
        fallbackSettings.photoQualityPrioritization = .speed
        photoOutput.setPreparedPhotoSettingsArray(preparedSettings.isEmpty ? [fallbackSettings] : preparedSettings) { _, _ in
            completion()
        }
    }

    func saveCapturedPhotoFromStream(
        _ image: UIImage?,
        data: Data?,
        capturedDeviceOrientation: UIDeviceOrientation,
        lensFacing: LensFacing,
        useLandscapeCanvas: Bool,
        aspectRatio: CameraAspectRatio = .full,
        portraitEffect: String? = nil,
        portraitStrength: Int = 5,
        portraitMask: CIImage? = nil,
        saveToPhotoLibrary: Bool = true
    ) async {
        let sourceImage = image ?? data.flatMap(UIImage.init(data:))
        let adjustedImage = sourceImage.map { $0.cropped(to: aspectRatio) }
        let adjustedData = aspectRatio == .full
            ? data
            : adjustedImage?.jpegData(compressionQuality: 0.94) ?? data
        lastCapturedImage = adjustedImage
        await saveCapturedPhoto(
            adjustedImage,
            data: adjustedData,
            portraitEffect: portraitEffect,
            portraitStrength: portraitStrength,
            portraitMask: portraitMask,
            saveToPhotoLibrary: saveToPhotoLibrary
        )
    }

    func saveCapturedVideoFromStream(_ url: URL?, error: Error?) async {
        guard error == nil, let url else {
            if let error {
                photoSaveMessage = "Video recording failed: \(error.localizedDescription)"
            } else {
                photoSaveMessage = "Video recording failed."
            }
            return
        }
        let outcome = await photoSaving.saveVideo(at: url)
        lastSavedPhotoURL = outcome.localURL
        photoSaveMessage = outcome.message
    }

    func capturePhoto(aspectRatio: CameraAspectRatio = .full, portraitEffect: String? = nil, portraitStrength: Int = 5, nightModeEnabled: Bool = false, completion: ((UIImage?) -> Void)? = nil) {
        if nightModeEnabled, let plan = nightModeState.plan, lensFacing == .back {
            captureNightModePhoto(aspectRatio: aspectRatio, plan: plan, completion: completion)
            return
        }

        capturePhotoFrame(aspectRatio: aspectRatio, qualityPrioritization: .speed, usesFlash: true, appliesLowLightBoost: false) { [weak self] image, data, diagnostics in
            guard let self else { return }
            self.lastCapturedImage = image
            completion?(image)
            Task { @MainActor in
                await self.saveCapturedPhoto(image, data: data, portraitEffect: portraitEffect, portraitStrength: portraitStrength, portraitMask: diagnostics.portraitMask)
            }
        }
    }

    private func captureNightModePhoto(aspectRatio: CameraAspectRatio, plan: NightModePlan, completion: ((UIImage?) -> Void)?) {
        guard !nightModeState.isBusy else { return }
        nightModeState = .capturing(plan, progress: 0)
        photoSaveMessage = nil
        lockExposureAndFocusForNightCapture()

        Task { @MainActor in
            let bracketFrames = await captureNightModeBracketFrames(aspectRatio: aspectRatio, plan: plan)
            var frames = bracketFrames
            if frames.isEmpty {
                for index in 0..<plan.frameCount {
                    guard !Task.isCancelled else { return }
                    applyNightModeExposureBias(plan.exposureBias(forFrame: index))
                    try? await Task.sleep(for: .milliseconds(90))
                    if let frame = await captureNightModeFrame(aspectRatio: aspectRatio) {
                        frames.append(frame)
                    }
                    let progress = Double(index + 1) / Double(plan.frameCount)
                    nightModeState = .capturing(plan, progress: progress)
                    if index < plan.frameCount - 1 {
                        try? await Task.sleep(for: .milliseconds(Int(plan.frameInterval * 1_000)))
                    }
                }
            } else {
                nightModeState = .capturing(plan, progress: 1.0)
            }

            nightModeState = .processing(plan)
            let processed = await Task.detached(priority: .userInitiated) {
                await NightModePhotoProcessor().process(frames: frames, plan: plan, aspectRatio: aspectRatio)
            }.value

            if let processed {
                lastCapturedImage = processed.image
                completion?(processed.image)
                await saveCapturedPhoto(processed.image, data: processed.data)
            } else if let fallback = frames.last {
                let data = fallback.jpegData(compressionQuality: 0.94)
                lastCapturedImage = fallback
                completion?(fallback)
                await saveCapturedPhoto(fallback, data: data)
            } else {
                photoSaveMessage = "Night capture failed. No usable frames were captured."
                completion?(nil)
            }

            restoreExposureAndFocusAfterNightCapture()
            updateNightModeStateFromCurrentDevice()
        }
    }

    private func captureNightModeBracketFrames(aspectRatio: CameraAspectRatio, plan: NightModePlan) async -> [UIImage] {
        await withCheckedContinuation { continuation in
            let photoOutput = photoOutput
            let capturedLensFacing = lensFacing
            let bracketCount = min(photoOutput.maxBracketedCapturePhotoCount, plan.frameCount)
            guard bracketCount >= 3 else {
                continuation.resume(returning: [])
                return
            }
            let bracketedSettings = (0..<bracketCount).map {
                AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: plan.exposureBias(forFrame: $0))
            }
            let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: 0, processedFormat: nil, bracketedSettings: bracketedSettings)
            settings.photoQualityPrioritization = .quality
            settings.isLensStabilizationEnabled = photoOutput.isLensStabilizationDuringBracketedCaptureSupported
            let uniqueID = Int64(settings.uniqueID)
            let delegate = BracketedPhotoCaptureDelegate { [weak self] images in
                Task { @MainActor in
                    self?.pendingPhotoDelegates[uniqueID] = nil
                    continuation.resume(returning: images.map { $0.cropped(to: aspectRatio) })
                }
            }
            pendingPhotoDelegates[uniqueID] = delegate
            sessionQueue.async { [weak self] in
                if let device = self?.currentInput?.device {
                    CameraDeviceControls.applyLowLightBoost(to: device, enabled: true)
                }
                configurePhotoConnection(photoOutput, lensFacing: capturedLensFacing)
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func captureNightModeFrame(aspectRatio: CameraAspectRatio) async -> UIImage? {
        await withCheckedContinuation { continuation in
            capturePhotoFrame(aspectRatio: aspectRatio, qualityPrioritization: .balanced, usesFlash: false, appliesLowLightBoost: true) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func capturePhotoFrame(
        aspectRatio: CameraAspectRatio,
        qualityPrioritization: AVCapturePhotoOutput.QualityPrioritization,
        usesFlash: Bool,
        appliesLowLightBoost: Bool,
        completion: @escaping (UIImage?, Data?, PhotoCaptureDiagnostics) -> Void
    ) {
        let selectedFlashMode = usesFlash ? flashMode.safeCameraFlashMode : "off"
        let capturedLensFacing = lensFacing
        let photoOutput = photoOutput
        let isPrepared = isPhotoOutputPrepared
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = qualityPrioritization
        let uniqueID = Int64(settings.uniqueID)
        let delegate = PhotoCaptureDelegate { [weak self] image, data, diagnostics in
            Task { @MainActor in
                let sourceImage = image ?? data.flatMap(UIImage.init(data:))
                let adjustedImage = sourceImage?.cropped(to: aspectRatio)
                let adjustedData = aspectRatio == .full
                    ? data
                    : adjustedImage?.jpegData(compressionQuality: 0.94) ?? data
                self?.pendingPhotoDelegates[uniqueID] = nil
                completion(adjustedImage, adjustedData, diagnostics)
            }
        }
        pendingPhotoDelegates[uniqueID] = delegate
        sessionQueue.async { [weak self] in
            let performCapture = {
                if appliesLowLightBoost, let device = self?.currentInput?.device {
                    CameraDeviceControls.applyLowLightBoost(to: device, enabled: true)
                }
                if let flashMode = selectedFlashMode.avCaptureFlashMode(supportedModes: photoOutput.supportedFlashModes, lensFacing: capturedLensFacing) {
                    settings.flashMode = flashMode
                }
                configurePhotoConnection(photoOutput, lensFacing: capturedLensFacing)
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }

            if isPrepared {
                performCapture()
            } else {
                Self.preparePhotoOutput(photoOutput) {
                    Task { @MainActor in self?.isPhotoOutputPrepared = true }
                    performCapture()
                }
            }
        }
    }

    private func configureAndStart() {
        isPhotoOutputPrepared = false
        let selectedLens = lensFacing
        let selectedZoom = zoomLevel
        let selectedExposureIndex = activeExposureIndex
        let session = session
        let photoOutput = photoOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let currentInput = self.currentInput { session.removeInput(currentInput) }
            do {
                let device = try Self.makeDevice(for: selectedLens, zoomLevel: selectedZoom)
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    return
                }
                session.addInput(input)
                self.currentInput = input
                if !session.outputs.contains(photoOutput) {
                    Self.configurePhotoOutputForSpeed(photoOutput)
                    if session.canAddOutput(photoOutput) {
                        session.addOutput(photoOutput)
                    }
                }
                self.boomerangCaptureManager.installVideoOutputIfNeeded(on: session, lensFacing: selectedLens)
                session.commitConfiguration()
                Self.preparePhotoOutput(photoOutput) {
                    Task { @MainActor in self.isPhotoOutputPrepared = true }
                }
                self.applyZoomOnQueue(selectedZoom, device: device)
                self.applyExposureOnQueue(selectedExposureIndex, device: device)
                if !session.isRunning { session.startRunning() }
                Task { @MainActor in
                    self.isRunning = session.isRunning
                    self.startNightModeMonitoring()
                }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in self.permissionState = .denied }
            }
        }
    }

    private func configureAndStartForPhotoCapture() async -> Bool {
        isPhotoOutputPrepared = false
        let selectedLens = lensFacing
        let selectedZoom = zoomLevel
        let selectedExposureIndex = activeExposureIndex
        let session = session
        let photoOutput = photoOutput

        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                session.beginConfiguration()
                session.sessionPreset = .photo
                if let currentInput = self.currentInput { session.removeInput(currentInput) }

                do {
                    let device = try Self.makeDevice(for: selectedLens, zoomLevel: selectedZoom)
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(returning: false)
                        return
                    }
                    session.addInput(input)
                    self.currentInput = input
                    if !session.outputs.contains(photoOutput) {
                        Self.configurePhotoOutputForSpeed(photoOutput)
                        if session.canAddOutput(photoOutput) {
                            session.addOutput(photoOutput)
                        }
                    }
                    self.boomerangCaptureManager.installVideoOutputIfNeeded(on: session, lensFacing: selectedLens)
                    session.commitConfiguration()
                    Self.preparePhotoOutput(photoOutput) {
                        Task { @MainActor in self.isPhotoOutputPrepared = true }
                    }
                    self.applyZoomOnQueue(selectedZoom, device: device)
                    self.applyExposureOnQueue(selectedExposureIndex, device: device)
                    if !session.isRunning { session.startRunning() }
                    let running = session.isRunning
                    Task { @MainActor in
                        self.isRunning = running
                        self.startNightModeMonitoring()
                    }
                    continuation.resume(returning: running)
                } catch {
                    session.commitConfiguration()
                    Task { @MainActor in self.permissionState = .denied }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func configureAndStartForBoomerangCapture() async -> Bool {
        isPhotoOutputPrepared = false
        let selectedLens = lensFacing
        let selectedZoom = zoomLevel
        let selectedExposureIndex = activeExposureIndex
        let session = session
        let photoOutput = photoOutput

        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                if session.canSetSessionPreset(.hd1280x720) {
                    session.sessionPreset = .hd1280x720
                } else if session.canSetSessionPreset(.high) {
                    session.sessionPreset = .high
                }
                if let currentInput = self.currentInput { session.removeInput(currentInput) }

                do {
                    let device = try Self.makeDevice(for: selectedLens, zoomLevel: selectedZoom)
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(returning: false)
                        return
                    }
                    session.addInput(input)
                    self.currentInput = input
                    if session.outputs.contains(photoOutput) {
                        session.removeOutput(photoOutput)
                    }
                    self.boomerangCaptureManager.installVideoOutputIfNeeded(on: session, lensFacing: selectedLens)
                    session.commitConfiguration()
                    self.applyBoomerangFrameRateOnQueue(device)
                    self.applyZoomOnQueue(selectedZoom, device: device)
                    self.applyExposureOnQueue(selectedExposureIndex, device: device)
                    session.startRunning()
                    let running = session.isRunning
                    Task { @MainActor in self.isRunning = running }
                    continuation.resume(returning: running)
                } catch {
                    session.commitConfiguration()
                    Task { @MainActor in self.permissionState = .denied }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func startNightModeMonitoring() {
        nightModeMotionMonitor.start()
        nightModeMonitorTask?.cancel()
        nightModeMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                updateNightModeStateFromCurrentDevice()
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }

    private func stopNightModeMonitoring() {
        nightModeMonitorTask?.cancel()
        nightModeMonitorTask = nil
        nightModeMotionMonitor.stop()
        nightModeState = .unavailable
    }

    private func updateNightModeStateFromCurrentDevice() {
        guard !nightModeState.isBusy else { return }
        let motionMagnitude = nightModeMotionMonitor.currentMagnitude()
        let userEnabled = isNightModeEnabledByUser
        let hasExistingNightPlan = nightModeState.plan != nil
        let selectedExposureIndex = activeExposureIndex
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            let metrics = NightModeSceneMetrics(
                exposureDuration: CMTimeGetSeconds(device.exposureDuration),
                iso: device.iso,
                exposureTargetOffset: device.exposureTargetOffset,
                isLowLightBoostSupported: device.isLowLightBoostSupported,
                isLowLightBoostEnabled: device.isLowLightBoostEnabled,
                lensFacing: device.position == .front ? .front : .back,
                deviceType: device.deviceType,
                motionMagnitude: motionMagnitude
            )
            let plan = NightModePlanner.plan(for: metrics)
            let previewEnabled = userEnabled && (plan != nil || hasExistingNightPlan) && metrics.lowLightScore >= NightModePlanner.disableThreshold * 0.55
            CameraDeviceControls.applyNightModePreview(to: device, enabled: previewEnabled, quality: plan?.quality ?? 0, exposureIndex: selectedExposureIndex)
            Task { @MainActor in
                self.applyNightModePlan(plan, lowLightScore: metrics.lowLightScore)
            }
        }
    }

    private func applyNightModePlan(_ plan: NightModePlan?, lowLightScore: Double) {
        let clearDisableThreshold = NightModePlanner.disableThreshold * 0.55
        switch nightModeState {
        case .active(let currentPlan):
            guard let plan else {
                if lowLightScore < clearDisableThreshold {
                    nightModeState = .unavailable
                } else {
                    nightModeState = isNightModeEnabledByUser ? .active(currentPlan) : .suggested(currentPlan)
                }
                return
            }
            nightModeState = isNightModeEnabledByUser ? .active(plan) : .suggested(plan)
        case .suggested(let currentPlan):
            guard let plan else {
                if lowLightScore < clearDisableThreshold {
                    nightModeState = .unavailable
                } else {
                    nightModeState = isNightModeEnabledByUser ? .active(currentPlan) : .suggested(currentPlan)
                }
                return
            }
            nightModeState = isNightModeEnabledByUser ? .active(plan) : .suggested(plan)
        case .unavailable:
            guard let plan, lowLightScore >= NightModePlanner.enableThreshold else { return }
            nightModeState = isNightModeEnabledByUser ? .active(plan) : .suggested(plan)
        case .capturing, .processing:
            break
        }
    }

    func setNightModeEnabledByUser(_ enabled: Bool) {
        isNightModeEnabledByUser = enabled
        updateNightModeStateFromCurrentDevice()
    }

    private func applyNightModeExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            CameraDeviceControls.applyExposureBias(to: device, bias: bias)
        }
    }

    private func lockExposureAndFocusForNightCapture() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = true
                }
                device.unlockForConfiguration()
            } catch {
                device.unlockForConfiguration()
            }
        }
    }

    private func restoreExposureAndFocusAfterNightCapture() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                device.unlockForConfiguration()
            }
        }
    }

    private func applyZoom(_ zoomLevel: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyZoomOnQueue(zoomLevel, device: device)
        }
    }

    private func applyZoomOnQueue(_ zoomLevel: Double, device: AVCaptureDevice) {
        CameraDeviceControls.applyZoom(to: device, zoomLevel: zoomLevel)
    }

    private func applyBoomerangFrameRateOnQueue(_ device: AVCaptureDevice) {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(BoomerangCaptureDefaults.targetFrameRate))
        do {
            try device.lockForConfiguration()
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { range in
                range.minFrameRate <= Double(BoomerangCaptureDefaults.targetFrameRate)
                    && Double(BoomerangCaptureDefaults.targetFrameRate) <= range.maxFrameRate
            }) {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
            device.unlockForConfiguration()
        } catch {
            return
        }
    }

    private func applyExposureOnQueue(_ exposureIndex: Int, device: AVCaptureDevice) {
        CameraDeviceControls.applyExposure(to: device, exposureIndex: exposureIndex)
    }

    private static func currentPermissionState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private func isUsingPreferredDevice(lensFacing: LensFacing, zoomLevel: Double) -> Bool {
        guard let device = currentInput?.device else { return true }
        guard lensFacing == .back else { return device.position == .front }
        return CameraBackDeviceSelection.isPreferred(device, zoomLevel: zoomLevel)
    }

    private static func makeDevice(for lensFacing: LensFacing, zoomLevel: Double) throws -> AVCaptureDevice {
        let position: AVCaptureDevice.Position = lensFacing == .back ? .back : .front
        if lensFacing == .back, let device = CameraBackDeviceSelection.preferredDevice(zoomLevel: zoomLevel) {
            return device
        }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) { return device }
        throw AVError(.deviceNotConnected)
    }

    private func saveCapturedPhoto(
        _ image: UIImage?,
        data originalData: Data?,
        portraitEffect: String? = nil,
        portraitStrength: Int = 5,
        portraitMask: CIImage? = nil,
        saveToPhotoLibrary: Bool = true
    ) async {
        if let image {
            lastCapturedImage = image
        }
        guard let originalData else {
            photoSaveMessage = "Capture failed. Original photo data was unavailable."
            return
        }

        var photoData = originalData
        var portraitProcessingSource: String?
        if let portraitEffect,
           let sourceImage = image ?? UIImage(data: originalData),
           let processedPhoto = portraitPhotoProcessor.makePortraitJPEGData(from: sourceImage, effect: portraitEffect, strength: portraitStrength, nativeMask: portraitMask) {
            photoData = processedPhoto.data
            portraitProcessingSource = processedPhoto.source
            lastCapturedImage = UIImage(data: processedPhoto.data) ?? sourceImage
        }

        let outcome: PhotoSaveOutcome
        if saveToPhotoLibrary {
            outcome = await photoSaving.savePhoto(photoData)
        } else {
            outcome = await photoSaving.savePhotoToAppStorage(photoData)
            let backgroundPhotoData = photoData
            let backgroundPhotoSaving = photoSaving
            Task.detached(priority: .utility) {
                _ = await backgroundPhotoSaving.savePhotoToCameraRoll(backgroundPhotoData)
            }
        }
        lastSavedPhotoURL = outcome.localURL
        if portraitEffect != nil, let portraitProcessingSource {
            photoSaveMessage = "\(outcome.message) Portrait: \(portraitProcessingSource)."
        } else if portraitEffect != nil {
            photoSaveMessage = "\(outcome.message) Portrait: normal fallback."
        } else {
            photoSaveMessage = outcome.message
        }
    }

}
