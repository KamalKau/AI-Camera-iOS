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
    @Published var lensFacing: LensFacing = .back
    @Published var zoomLevel: Double = 1.0
    @Published var flashMode = "off"

    var flashEnabled: Bool { flashMode != "off" }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let portraitPhotoProcessor = PortraitPhotoProcessor()
    private var isPhotoOutputPrepared = false
    private var currentInput: AVCaptureDeviceInput?
    private var pendingPhotoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private let photoSaving: any PhotoSaving
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
        self.zoomLevel = max(1.0, min(8.0, zoomLevel))
        self.flashMode = flashMode.safeCameraFlashMode
        return await configureAndStartForPhotoCapture()
    }

    func stop() {
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    func stopAndWait() async {
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
        let clampedZoom = max(1.0, min(8.0, zoomLevel))
        let shouldSwitchLens = self.lensFacing != lensFacing
        self.lensFacing = lensFacing
        self.zoomLevel = clampedZoom
        self.flashMode = flashMode.safeCameraFlashMode
        shouldSwitchLens ? configureAndStart() : applyZoom(clampedZoom)
    }

    func applyExposureIndex(_ exposureIndex: Int) {
        let clampedIndex = min(8, max(-8, exposureIndex))
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyExposureOnQueue(clampedIndex, device: device)
        }
    }

    func switchLens() {
        apply(lensFacing: lensFacing == .back ? .front : .back, zoomLevel: zoomLevel, flashMode: flashMode)
    }

    private func prewarmPhotoStorageIfNeeded() {
        guard !didPrewarmPhotoStorage else { return }
        didPrewarmPhotoStorage = true
        Task { [photoSaving] in
            await photoSaving.prewarm()
        }
    }

    private nonisolated static func configurePhotoOutputForSpeed(_ photoOutput: AVCapturePhotoOutput) {
        photoOutput.maxPhotoQualityPrioritization = .speed
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

    func capturePhoto(aspectRatio: CameraAspectRatio = .full, portraitEffect: String? = nil, portraitStrength: Int = 5, completion: ((UIImage?) -> Void)? = nil) {
        let selectedFlashMode = flashMode.safeCameraFlashMode
        let capturedLensFacing = lensFacing
        let photoOutput = photoOutput
        let isPrepared = isPhotoOutputPrepared
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed
        Self.configurePortraitPhotoSettings(settings, output: photoOutput, enabled: portraitEffect != nil)
        let uniqueID = Int64(settings.uniqueID)
        let delegate = PhotoCaptureDelegate { [weak self] image, data, diagnostics in
            Task { @MainActor in
                let adjustedImage = image?.cropped(to: aspectRatio)
                let adjustedData = aspectRatio == .full
                    ? data
                    : adjustedImage?.jpegData(compressionQuality: 0.94) ?? data
                self?.lastCapturedImage = adjustedImage
                self?.pendingPhotoDelegates[uniqueID] = nil
                completion?(adjustedImage)
                Task { @MainActor in
                    await self?.saveCapturedPhoto(adjustedImage, data: adjustedData, portraitEffect: portraitEffect, portraitStrength: portraitStrength, portraitMask: diagnostics.portraitMask)
                }
            }
        }
        pendingPhotoDelegates[uniqueID] = delegate
        sessionQueue.async { [weak self] in
            let performCapture = {
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
        let session = session
        let photoOutput = photoOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let currentInput = self.currentInput { session.removeInput(currentInput) }
            do {
                let device = try Self.makeDevice(for: selectedLens)
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
                session.commitConfiguration()
                Self.preparePhotoOutput(photoOutput) {
                    Task { @MainActor in self.isPhotoOutputPrepared = true }
                }
                self.applyZoomOnQueue(selectedZoom, device: device)
                self.applyExposureOnQueue(0, device: device)
                if !session.isRunning { session.startRunning() }
                Task { @MainActor in self.isRunning = session.isRunning }
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
                    let device = try Self.makeDevice(for: selectedLens)
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
                        session.commitConfiguration()
                    Self.preparePhotoOutput(photoOutput) {
                        Task { @MainActor in self.isPhotoOutputPrepared = true }
                    }
                    self.applyZoomOnQueue(selectedZoom, device: device)
                    self.applyExposureOnQueue(0, device: device)
                    if !session.isRunning { session.startRunning() }
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

    private func applyZoom(_ zoomLevel: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyZoomOnQueue(zoomLevel, device: device)
        }
    }

    private func applyZoomOnQueue(_ zoomLevel: Double, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(maxZoom, zoomLevel))
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func applyExposureOnQueue(_ exposureIndex: Int, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let targetBias = Float(exposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
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

    private static func makeDevice(for lensFacing: LensFacing) throws -> AVCaptureDevice {
        let position: AVCaptureDevice.Position = lensFacing == .back ? .back : .front
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

