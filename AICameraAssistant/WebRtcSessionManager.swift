@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation
import UIKit
#if canImport(WebRTC)
import WebRTC
#endif

@MainActor
protocol WebRtcSessionManaging: AnyObject {
    var state: WebRtcConnectionState { get }
    func startHost(roomCode: String, repository: any RoomSignalingRepository) async
    func startController(roomCode: String, repository: any RoomSignalingRepository) async
    func stop()
}

enum WebRtcConnectionState: String {
    case idle
    case connecting
    case waitingForVideo
    case connected
    case unavailable
    case failed
}

#if canImport(WebRTC)
final class LocalFrameSnapshotRenderer: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let recordingQueue = DispatchQueue(label: "webrtc.local-frame-recorder.queue")
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestRotationDegrees = 0
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTimestampNs: Int64?
    private var recordingOutputURL: URL?
    private var isRecordingMirrored = false
    private var isFinishingRecording = false

    var isRecording: Bool {
        recordingQueue.sync { assetWriter != nil && !isFinishingRecording }
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame,
              let cvBuffer = frame.buffer as? RTCCVPixelBuffer else { return }
        let pixelBuffer = cvBuffer.pixelBuffer
        let rotationDegrees = Int(frame.rotation.rawValue)
        lock.lock()
        latestPixelBuffer = pixelBuffer
        latestRotationDegrees = rotationDegrees
        lock.unlock()
        appendFrame(pixelBuffer, timestampNs: frame.timeStampNs, rotationDegrees: rotationDegrees)
    }

    func startVideoRecording(to outputURL: URL, isMirrored: Bool) {
        recordingQueue.async { [weak self] in
            guard let self else { return }
            resetRecordingState()
            recordingOutputURL = outputURL
            isRecordingMirrored = isMirrored
            isFinishingRecording = false
        }
    }

    func stopVideoRecording(completion: @escaping (URL?) -> Void) {
        recordingQueue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            guard let writer = assetWriter, let outputURL = recordingOutputURL else {
                resetRecordingState()
                completion(nil)
                return
            }
            isFinishingRecording = true
            videoInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                let completedURL = writer.status == .completed ? outputURL : nil
                self?.recordingQueue.async {
                    self?.resetRecordingState()
                    completion(completedURL)
                }
            }
        }
    }

    func snapshotImage(isMirrored: Bool, appliesFrameRotation: Bool, correctsFrontLandscapeUpsideDown: Bool) -> UIImage? {
        lock.lock()
        let pixelBuffer = latestPixelBuffer
        let rotationDegrees = latestRotationDegrees
        lock.unlock()
        guard let pixelBuffer else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if appliesFrameRotation {
            image = image.oriented(cgImageOrientation(forWebRtcRotationDegrees: rotationDegrees))
        } else if correctsFrontLandscapeUpsideDown {
            image = image.oriented(.down)
        }
        image = normalizedToZeroOrigin(image)
        if isMirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
            image = normalizedToZeroOrigin(image)
        }
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
    }

    private func appendFrame(_ pixelBuffer: CVPixelBuffer, timestampNs: Int64, rotationDegrees: Int) {
        recordingQueue.async { [weak self] in
            guard let self,
                  recordingOutputURL != nil,
                  !isFinishingRecording else { return }
            do {
                if assetWriter == nil {
                    try startWriter(pixelBuffer: pixelBuffer, timestampNs: timestampNs, rotationDegrees: rotationDegrees)
                }
                guard let adaptor = pixelBufferAdaptor,
                      let input = videoInput,
                      input.isReadyForMoreMediaData,
                      let recordingStartTimestampNs else { return }
                let presentationTime = CMTime(
                    value: max(0, timestampNs - recordingStartTimestampNs),
                    timescale: 1_000_000_000
                )
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            } catch {
                resetRecordingState()
            }
        }
    }

    private func startWriter(pixelBuffer: CVPixelBuffer, timestampNs: Int64, rotationDegrees: Int) throws {
        guard let recordingOutputURL else { return }
        try? FileManager.default.removeItem(at: recordingOutputURL)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let writer = try AVAssetWriter(outputURL: recordingOutputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoExpectedSourceFrameRateKey: 20,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = assetTrackTransform(width: width, height: height, rotationDegrees: rotationDegrees, isMirrored: isRecordingMirrored)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw WebRtcSessionError.cameraUnavailable }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        assetWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor
        recordingStartTimestampNs = timestampNs
    }

    private func assetTrackTransform(width: Int, height: Int, rotationDegrees: Int, isMirrored: Bool) -> CGAffineTransform {
        let rotatedTransform: CGAffineTransform
        let displayWidth: CGFloat
        switch rotationDegrees {
        case 90:
            rotatedTransform = CGAffineTransform(translationX: CGFloat(height), y: 0).rotated(by: .pi / 2)
            displayWidth = CGFloat(height)
        case 180:
            rotatedTransform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
            displayWidth = CGFloat(width)
        case 270:
            rotatedTransform = CGAffineTransform(translationX: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
            displayWidth = CGFloat(height)
        default:
            rotatedTransform = .identity
            displayWidth = CGFloat(width)
        }
        guard isMirrored else { return rotatedTransform }
        let mirrorTransform = CGAffineTransform(translationX: displayWidth, y: 0).scaledBy(x: -1, y: 1)
        return rotatedTransform.concatenating(mirrorTransform)
    }

    private func resetRecordingState() {
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        recordingStartTimestampNs = nil
        recordingOutputURL = nil
        isRecordingMirrored = false
        isFinishingRecording = false
    }

    private func cgImageOrientation(forWebRtcRotationDegrees degrees: Int) -> CGImagePropertyOrientation {
        switch degrees {
        case 90:
            return .right
        case 180:
            return .down
        case 270:
            return .left
        default:
            return .up
        }
    }

    private func normalizedToZeroOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
#endif

@MainActor
final class WebRtcSessionManager: NSObject, ObservableObject, WebRtcSessionManaging {
    @Published private(set) var state: WebRtcConnectionState = .idle
    @Published private(set) var streamQualityMode: StreamQualityMode = .lowLatency
    @Published private(set) var capturedLensFacing: LensFacing = .back
    @Published private(set) var decodedVideoFrameCount = 0
    @Published private(set) var reconnectCount = 0
    @Published private(set) var iceConnectionStateDescription = "idle"
    #if canImport(WebRTC)
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private var localVideoSource: RTCVideoSource?
    private var localFrameSnapshotRenderer: LocalFrameSnapshotRenderer?
    private var videoSender: RTCRtpSender?
    private var role: WebRtcRole = .host
    private var roomCode: String?
    private var rtcSessionId: String?
    private var repository: (any RoomSignalingRepository)?
    private var signalingTask: Task<Void, Never>?
    private var candidatePollingTask: Task<Void, Never>?
    private let streamHealthMonitor = StreamHealthMonitor()
    private var capturedLensCommitTask: Task<Void, Never>?
    private var captureSwitchGeneration = 0
    private var appliedRemoteCandidateIDs = Set<String>()
    private var activeCaptureDevice: AVCaptureDevice?
    private var activeLensFacing: LensFacing = .back
    private var activeZoomLevel = 1.0
    private var activeFlashMode = "off"
    private let hostCaptureQueue = DispatchQueue(label: "webrtc.host.capture.queue", qos: .userInitiated)
    private let hostPhotoOutput = AVCapturePhotoOutput()
    private let hostMovieOutput = AVCaptureMovieFileOutput()
    private var hostAudioInput: AVCaptureDeviceInput?
    private var hostAudioRecorder: AVAudioRecorder?
    private var hostStandaloneAudioSegments: [URL] = []
    private var pendingHostPhotoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var hostMovieDelegate: MovieCaptureDelegate?
    private var hostRecordingSegments: [URL] = []
    private var hostRecordingCompletion: ((URL?, Error?) -> Void)?
    private var pendingRecordingLensFacing: LensFacing?
    private var shouldFinalizeHostRecording = false
    @Published private(set) var isHostVideoRecording = false
    @Published private(set) var isHostVideoPaused = false
    private var isPreparingHostVideoRecording = false
    private var activeExposureIndex = 0
    private var isRestartingCapture = false
    private var isThrottlingLocalStreamForRecording = false
    #endif

    override init() {
        super.init()
        #if canImport(WebRTC)
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        #endif
    }

    func startHost(roomCode: String, repository: any RoomSignalingRepository) async {
        await startHost(roomCode: roomCode, repository: repository, preserveLocalCapture: false)
    }

    private func startHost(
        roomCode: String,
        repository: any RoomSignalingRepository,
        preserveLocalCapture: Bool
    ) async {
        #if canImport(WebRTC)
        let canStart = state == .idle || state == .unavailable || state == .failed || (preserveLocalCapture && state == .connecting)
        guard canStart else { return }
        state = .connecting
        self.role = .host
        self.roomCode = roomCode
        self.repository = repository
        self.rtcSessionId = nil

        do {
            let peerConnection = try makePeerConnection()
            self.peerConnection = peerConnection
            try attachCameraTrack(to: peerConnection, preserveLocalCapture: preserveLocalCapture)
            observeSignaling(roomCode: roomCode, repository: repository)
        } catch {
            state = .failed
        }
        #else
        state = .unavailable
        #endif
    }

    func startController(roomCode: String, repository: any RoomSignalingRepository) async {
        await startController(roomCode: roomCode, repository: repository, preserveRemotePreview: false)
    }

    private func startController(
        roomCode: String,
        repository: any RoomSignalingRepository,
        preserveRemotePreview: Bool
    ) async {
        #if canImport(WebRTC)
        let canStart = state == .idle || state == .unavailable || state == .failed || (preserveRemotePreview && state == .connecting)
        guard canStart else { return }
        state = .connecting
        self.role = .controller
        self.roomCode = roomCode
        self.repository = repository
        let rtcSessionId = UUID().uuidString
        self.rtcSessionId = rtcSessionId
        if !preserveRemotePreview {
            self.remoteVideoTrack = nil
        }

        do {
            let peerConnection = try makePeerConnection()
            self.peerConnection = peerConnection
            let offer = try await makeOffer(on: peerConnection)
            try await peerConnection.setLocalDescriptionAsync(offer)
            try await repository.setOffer(offer.sdp, roomCode: roomCode, rtcSessionId: rtcSessionId)
            observeSignaling(roomCode: roomCode, repository: repository)
        } catch {
            if !preserveRemotePreview {
                self.remoteVideoTrack = nil
            }
            state = .failed
        }
        #else
        state = .unavailable
        #endif
    }

    func stop() {
        #if canImport(WebRTC)
        signalingTask?.cancel()
        signalingTask = nil
        candidatePollingTask?.cancel()
        candidatePollingTask = nil
        streamHealthMonitor.cancel()
        capturedLensCommitTask?.cancel()
        capturedLensCommitTask = nil
        if localFrameSnapshotRenderer?.isRecording == true {
            localFrameSnapshotRenderer?.stopVideoRecording { _ in }
        }
        removeHostMovieOutput()
        cameraCapturer?.stopCapture()
        cameraCapturer = nil
        localFrameSnapshotRenderer = nil
        localVideoSource = nil
        videoSender = nil
        activeCaptureDevice = nil
        hostMovieDelegate = nil
        hostRecordingSegments.removeAll()
        hostStandaloneAudioSegments.removeAll()
        hostAudioRecorder?.stop()
        hostAudioRecorder = nil
        hostRecordingCompletion = nil
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = false
        hostAudioInput = nil
        isPreparingHostVideoRecording = false
        isHostVideoRecording = false
        isHostVideoPaused = false
        isThrottlingLocalStreamForRecording = false
        pendingHostPhotoDelegates.removeAll()
        activeExposureIndex = 0
        capturedLensFacing = .back
        localVideoTrack = nil
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        #endif
        state = .idle
        iceConnectionStateDescription = "idle"
    }

    func applyStreamQualityMode(_ mode: StreamQualityMode) {
        streamQualityMode = mode
        #if canImport(WebRTC)
        if let videoSender {
            configureVideoSender(videoSender)
        }
        adaptLocalVideoSource()
        #endif
    }

    func applyCameraControls(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        let clampedZoom = max(1.0, min(8.0, zoomLevel))
        let shouldSwitchLens = activeLensFacing != lensFacing
        activeZoomLevel = clampedZoom
        activeFlashMode = flashMode.safeCameraFlashMode

        if shouldSwitchLens {
            guard !isHostVideoRecording, !isPreparingHostVideoRecording else {
                switchRecordingLens(to: lensFacing)
                return
            }
            switchCapture(to: lensFacing)
        } else {
            applyDeviceControls(zoomLevel: clampedZoom)
        }
        #endif
    }

    func applyFocusPoint(x: Double, y: Double, lockEnabled: Bool) {
        #if canImport(WebRTC)
        guard role == .host, let device = activeCaptureDevice else { return }
        do {
            try device.lockForConfiguration()
            let point = CGPoint(x: min(1.0, max(0.0, x)), y: min(1.0, max(0.0, y)))
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = lockEnabled ? .locked : .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = lockEnabled ? .locked : .continuousAutoExposure
            }
            let targetBias = Float(activeExposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
        #endif
    }

    func applyExposureIndex(_ exposureIndex: Int) {
        #if canImport(WebRTC)
        let clampedIndex = min(8, max(-8, exposureIndex))
        guard activeExposureIndex != clampedIndex else { return }
        activeExposureIndex = clampedIndex
        guard role == .host, let device = activeCaptureDevice else { return }
        applyExposureOnDevice(device, exposureIndex: clampedIndex)
        #endif
    }

    func pauseHostVideoCapture() async {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        await withCheckedContinuation { continuation in
            cameraCapturer.stopCapture {
                continuation.resume()
            }
        }
        activeCaptureDevice = nil
        #endif
    }

    func resumeHostVideoCapture() {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        do {
            try startCapture(cameraCapturer, lensFacing: activeLensFacing)
        } catch {
            state = .failed
        }
        #endif
    }

    func captureHostPhoto(wantsPortraitMatte: Bool = false, completion: @escaping (UIImage?, Data?, UIDeviceOrientation, LensFacing, Bool, CIImage?) -> Void) {
        #if canImport(WebRTC)
        let capturedDeviceOrientation = currentDeviceCaptureOrientation()
        let capturedLensFacing = activeCaptureDevice.map { $0.position == .front ? LensFacing.front : .back } ?? activeLensFacing
        guard role == .host, !isRestartingCapture else {
            completion(nil, nil, capturedDeviceOrientation, capturedLensFacing, capturedDeviceOrientation.isLandscape, nil)
            return
        }

        let isLandscapeCapture = capturedDeviceOrientation.isLandscape
        let shouldCorrectFrontLandscape = capturedLensFacing == .front && isLandscapeCapture
        guard let image = localFrameSnapshotRenderer?.snapshotImage(
            isMirrored: capturedLensFacing == .front,
            appliesFrameRotation: !isLandscapeCapture,
            correctsFrontLandscapeUpsideDown: shouldCorrectFrontLandscape
        ) else {
            completion(nil, nil, capturedDeviceOrientation, capturedLensFacing, capturedDeviceOrientation.isLandscape, nil)
            return
        }
        let data = image.jpegData(compressionQuality: 0.94)
        completion(image, data, capturedDeviceOrientation, capturedLensFacing, capturedDeviceOrientation.isLandscape, nil)
        #else
        let capturedDeviceOrientation = currentDeviceCaptureOrientation()
        completion(nil, nil, capturedDeviceOrientation, activeLensFacing, false, nil)
        #endif
    }

    func startHostVideoRecording(completion: @escaping (URL?, Error?) -> Void) {
        #if canImport(WebRTC)
        guard role == .host, !isHostVideoRecording, !isPreparingHostVideoRecording else { return }
        hostRecordingSegments.removeAll()
        hostStandaloneAudioSegments.removeAll()
        hostAudioRecorder?.stop()
        hostAudioRecorder = nil
        hostRecordingCompletion = completion
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = false
        isHostVideoRecording = true
        isHostVideoPaused = false
        setLocalStreamThrottledForRecording(true)
        startHostRecordingSegment()
        #endif
    }

    func pauseHostVideoRecording() {
        #if canImport(WebRTC)
        guard isHostVideoRecording, !isHostVideoPaused else { return }
        isHostVideoPaused = true
        isPreparingHostVideoRecording = false
        stopCurrentFrameRecordingSegment(finalizeAfterStop: false)
        #endif
    }

    func resumeHostVideoRecording() {
        #if canImport(WebRTC)
        guard isHostVideoRecording, isHostVideoPaused, localFrameSnapshotRenderer?.isRecording != true else { return }
        isHostVideoPaused = false
        startHostRecordingSegment()
        #endif
    }

    func stopHostVideoRecording() {
        #if canImport(WebRTC)
        isPreparingHostVideoRecording = false
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = true
        isHostVideoPaused = false
        stopCurrentFrameRecordingSegment(finalizeAfterStop: true)
        #endif
    }

    func finishHostVideoRecordingBeforeTeardown() async {
        #if canImport(WebRTC)
        guard isHostVideoRecording || isPreparingHostVideoRecording || localFrameSnapshotRenderer?.isRecording == true else { return }
        await withCheckedContinuation { continuation in
            let existingCompletion = hostRecordingCompletion
            var didResume = false
            hostRecordingCompletion = { url, error in
                existingCompletion?(url, error)
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }
            stopHostVideoRecording()
        }
        #endif
    }

    #if canImport(WebRTC)
    private func makePeerConnection() throws -> RTCPeerConnection {
        guard let factory else { throw WebRtcSessionError.factoryUnavailable }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw WebRtcSessionError.peerConnectionUnavailable
        }
        return peerConnection
    }

    private func attachCameraTrack(to peerConnection: RTCPeerConnection, preserveLocalCapture: Bool) throws {
        if preserveLocalCapture, let localVideoTrack, let cameraCapturer {
            if let sender = peerConnection.add(localVideoTrack, streamIds: ["camera-stream"]) {
                videoSender = sender
                configureVideoSender(sender)
            }
            return
        }

        try startCameraTrack(on: peerConnection)
    }

    private func startCameraTrack(on peerConnection: RTCPeerConnection) throws {
        guard let factory else { throw WebRtcSessionError.factoryUnavailable }
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoSource = videoSource
        adaptLocalVideoSource()
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "camera-video")
        let snapshotRenderer = LocalFrameSnapshotRenderer()
        videoTrack.add(snapshotRenderer)
        localFrameSnapshotRenderer = snapshotRenderer
        if let sender = peerConnection.add(videoTrack, streamIds: ["camera-stream"]) {
            videoSender = sender
            configureVideoSender(sender)
        }

        cameraCapturer = capturer
        localVideoTrack = videoTrack
        Self.configureHostPhotoOutput(hostPhotoOutput, on: capturer)
        try startCapture(capturer, lensFacing: activeLensFacing)
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

    private nonisolated static func configureHostPhotoOutput(
        _ photoOutput: AVCapturePhotoOutput,
        on capturer: RTCCameraVideoCapturer,
        completion: @escaping () -> Void = {}
    ) {
        let session = capturer.captureSession
        guard !session.outputs.contains(photoOutput) else {
            completion()
            return
        }
        Self.configurePhotoOutputForSpeed(photoOutput)
        guard session.canAddOutput(photoOutput) else {
            completion()
            return
        }
        session.beginConfiguration()
        session.addOutput(photoOutput)
        session.commitConfiguration()
        Self.preparePhotoOutput(photoOutput, completion: completion)
    }

    private nonisolated static func configureHostMovieVideoOutput(
        _ movieOutput: AVCaptureMovieFileOutput,
        on capturer: RTCCameraVideoCapturer
    ) {
        let session = capturer.captureSession
        guard !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) else { return }
        session.beginConfiguration()
        session.addOutput(movieOutput)
        session.commitConfiguration()
    }

    private func switchRecordingLens(to lensFacing: LensFacing) {
        guard pendingRecordingLensFacing != lensFacing else { return }
        pendingRecordingLensFacing = lensFacing
        guard localFrameSnapshotRenderer?.isRecording == true else {
            switchCapture(to: lensFacing) { [weak self] in
                self?.startHostRecordingSegment()
            }
            return
        }
        stopCurrentFrameRecordingSegment(finalizeAfterStop: false)
    }

    private func switchCapture(to lensFacing: LensFacing, completion: (() -> Void)? = nil) {
        guard let cameraCapturer, !isRestartingCapture else { return }
        activeLensFacing = lensFacing
        activeCaptureDevice = nil
        isRestartingCapture = true
        captureSwitchGeneration += 1
        let switchGeneration = captureSwitchGeneration
        var didRestart = false

        func restartIfNeeded() {
            guard !didRestart, captureSwitchGeneration == switchGeneration else { return }
            didRestart = true
            let profile = streamQualityMode.webRtcProfile.adjusted(for: activeLensFacing)
            let zoomLevel = activeZoomLevel
            let exposureIndex = activeExposureIndex
            hostCaptureQueue.async { [weak self] in
                do {
                    let device = try Self.startCaptureOnCapturer(cameraCapturer, lensFacing: lensFacing, profile: profile)
                    Self.applyDeviceControls(device, zoomLevel: zoomLevel)
                    Self.applyExposureOnDevice(device, exposureIndex: exposureIndex)
                    Task { @MainActor in
                        guard let self, self.captureSwitchGeneration == switchGeneration else { return }
                        self.activeCaptureDevice = device
                        self.activeLensFacing = lensFacing
                        self.publishPreviewSize(profile)
                        self.isRestartingCapture = false
                        self.capturedLensCommitTask?.cancel()
                        self.capturedLensCommitTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled, self.captureSwitchGeneration == switchGeneration else { return }
                            self.capturedLensFacing = lensFacing
                        }
                        completion?()
                    }
                } catch {
                    Task { @MainActor in
                        guard let self else { return }
                        self.isRestartingCapture = false
                        self.state = .failed
                        self.finalizeHostRecording(error: error)
                    }
                }
            }
        }

        cameraCapturer.stopCapture { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                restartIfNeeded()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard captureSwitchGeneration == switchGeneration, isRestartingCapture else { return }
            restartIfNeeded()
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                return false
            }
            return await withCheckedContinuation { continuation in
                let lock = NSLock()
                var didResume = false

                func resume(_ granted: Bool) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: granted)
                }

                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    resume(granted)
                }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    resume(false)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func activateHostAudioSession() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureHostMovieOutput(on capturer: RTCCameraVideoCapturer, activateAudioSession: Bool = true) async throws {
        let session = capturer.captureSession
        if activateAudioSession {
            try activateHostAudioSession()
        }
        let movieOutput = hostMovieOutput
        let existingAudioInput = hostAudioInput
        let newAudioInput: AVCaptureDeviceInput?
        if activateAudioSession, existingAudioInput == nil {
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw AVError(.deviceNotConnected)
            }
            newAudioInput = try AVCaptureDeviceInput(device: microphone)
        } else {
            newAudioInput = nil
        }

        let configuredAudioInput = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVCaptureDeviceInput?, Error>) in
            hostCaptureQueue.async {
                var didBeginConfiguration = false
                do {
                    session.beginConfiguration()
                    didBeginConfiguration = true
                    let audioInput = existingAudioInput ?? newAudioInput
                    if let audioInput, !session.inputs.contains(audioInput) {
                        guard session.canAddInput(audioInput) else {
                            throw AVError(.deviceInUseByAnotherApplication)
                        }
                        session.addInput(audioInput)
                    }

                    if !session.outputs.contains(movieOutput) {
                        guard session.canAddOutput(movieOutput) else {
                            throw WebRtcSessionError.cameraUnavailable
                        }
                        session.addOutput(movieOutput)
                    }
                    session.commitConfiguration()
                    continuation.resume(returning: audioInput)
                } catch {
                    if didBeginConfiguration {
                        session.commitConfiguration()
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
        hostAudioInput = configuredAudioInput
    }

    private func removeHostMovieOutput() {
        guard let cameraCapturer else { return }
        let session = cameraCapturer.captureSession
        guard !hostMovieOutput.isRecording else { return }
        let movieOutput = hostMovieOutput
        let shouldRemoveOutput = session.outputs.contains(hostMovieOutput)
        let audioInput = hostAudioInput
        let shouldRemoveAudioInput = audioInput.map { session.inputs.contains($0) } ?? false
        guard shouldRemoveOutput || shouldRemoveAudioInput else { return }
        hostCaptureQueue.async { [weak self] in
            session.beginConfiguration()
            if shouldRemoveOutput {
                session.removeOutput(movieOutput)
            }
            if let audioInput, shouldRemoveAudioInput {
                session.removeInput(audioInput)
            }
            session.commitConfiguration()
            if shouldRemoveAudioInput {
                Task { @MainActor in self?.hostAudioInput = nil }
            }
        }
    }

    private func startHostRecordingSegment() {
        guard isHostVideoRecording,
              localFrameSnapshotRenderer?.isRecording != true,
              !isPreparingHostVideoRecording else { return }
        isPreparingHostVideoRecording = true
        Task { @MainActor in
            do {
                _ = try await readyCameraCapturerForRecording()
                guard isHostVideoRecording,
                      !isHostVideoPaused,
                      isPreparingHostVideoRecording,
                      let recorder = localFrameSnapshotRenderer else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AI-Camera-\(UUID().uuidString)")
                    .appendingPathExtension("mov")
                recorder.startVideoRecording(to: url, isMirrored: activeLensFacing == .front)
                startStandaloneAudioRecordingSegment()
                isPreparingHostVideoRecording = false
            } catch {
                isPreparingHostVideoRecording = false
                finalizeHostRecording(error: error)
            }
        }
    }

    private func startStandaloneAudioRecordingSegment() {
        guard hostAudioRecorder == nil else { return }
        Task { @MainActor in
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
                  await ensureMicrophoneAccess(),
                  isHostVideoRecording,
                  !isHostVideoPaused else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothHFP, .defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AI-Camera-Audio-\(UUID().uuidString)")
                    .appendingPathExtension("m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.prepareToRecord()
                recorder.record()
                hostAudioRecorder = recorder
            } catch {
                hostAudioRecorder = nil
            }
        }
    }

    private func stopStandaloneAudioRecordingSegment() {
        guard let recorder = hostAudioRecorder else { return }
        let url = recorder.url
        recorder.stop()
        hostAudioRecorder = nil
        if isUsableRecordingSegment(url) {
            hostStandaloneAudioSegments.append(url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stopCurrentFrameRecordingSegment(finalizeAfterStop: Bool) {
        stopStandaloneAudioRecordingSegment()
        guard let recorder = localFrameSnapshotRenderer, recorder.isRecording else {
            if finalizeAfterStop {
                finalizeHostRecording(error: nil)
            }
            return
        }
        recorder.stopVideoRecording { [weak self] outputURL in
            Task { @MainActor in
                guard let self else { return }
                if let outputURL, self.isUsableRecordingSegment(outputURL) {
                    self.hostRecordingSegments.append(outputURL)
                }
                if let pendingRecordingLensFacing = self.pendingRecordingLensFacing, !self.shouldFinalizeHostRecording {
                    self.pendingRecordingLensFacing = nil
                    self.switchCapture(to: pendingRecordingLensFacing) { [weak self] in
                        self?.startHostRecordingSegment()
                    }
                    return
                }
                if finalizeAfterStop || self.shouldFinalizeHostRecording {
                    self.finalizeHostRecording(error: nil)
                }
            }
        }
    }

    private func finalizeHostRecording(error: Error?) {
        stopStandaloneAudioRecordingSegment()
        let completion = hostRecordingCompletion
        let segments = hostRecordingSegments
        let audioSegments = hostStandaloneAudioSegments
        hostRecordingCompletion = nil
        hostRecordingSegments.removeAll()
        hostStandaloneAudioSegments.removeAll()
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = false
        isPreparingHostVideoRecording = false
        isHostVideoRecording = false
        isHostVideoPaused = false
        setLocalStreamThrottledForRecording(false)

        if let error {
            completion?(nil, error)
            return
        }
        guard let completion else { return }
        Task {
            do {
                let videoURL: URL?
                if segments.count <= 1 {
                    videoURL = segments.first
                } else {
                    videoURL = try await mergeRecordingSegments(segments)
                }
                guard let videoURL else {
                    await MainActor.run { completion(nil, nil) }
                    return
                }
                let finalURL = audioSegments.isEmpty
                    ? videoURL
                    : try await mergeStandaloneAudioSegments(audioSegments, into: videoURL)
                await MainActor.run { completion(finalURL, nil) }
            } catch {
                await MainActor.run {
                    completion(segments.first, nil)
                }
            }
        }
    }

    private func isUsableRecordingSegment(_ url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    private func mergeRecordingSegments(_ segments: [URL]) async throws -> URL {
        struct SegmentInfo {
            let asset: AVURLAsset
            let videoTrack: AVAssetTrack
            let audioTrack: AVAssetTrack?
            let duration: CMTime
            let naturalSize: CGSize
            let preferredTransform: CGAffineTransform
            let orientedRect: CGRect
        }

        var segmentInfos: [SegmentInfo] = []
        var renderSize = CGSize.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else { continue }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
            renderSize.width = max(renderSize.width, abs(orientedRect.width))
            renderSize.height = max(renderSize.height, abs(orientedRect.height))
            segmentInfos.append(SegmentInfo(
                asset: asset,
                videoTrack: sourceVideo,
                audioTrack: sourceAudio,
                duration: duration,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                orientedRect: orientedRect
            ))
        }
        guard !segmentInfos.isEmpty, renderSize != .zero else { throw WebRtcSessionError.cameraUnavailable }
        renderSize.width = ceil(renderSize.width / 2.0) * 2.0
        renderSize.height = ceil(renderSize.height / 2.0) * 2.0

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for info in segmentInfos {
            guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw WebRtcSessionError.cameraUnavailable
            }
            let timeRange = CMTimeRange(start: .zero, duration: info.duration)
            try compositionVideoTrack.insertTimeRange(timeRange, of: info.videoTrack, at: cursor)
            if let sourceAudio = info.audioTrack,
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: info.duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            let positiveSpaceTransform = info.preferredTransform.concatenating(
                CGAffineTransform(translationX: -info.orientedRect.minX, y: -info.orientedRect.minY)
            )
            let orientedSize = CGSize(width: abs(info.orientedRect.width), height: abs(info.orientedRect.height))
            let fillScale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
            let scaledSize = CGSize(width: orientedSize.width * fillScale, height: orientedSize.height * fillScale)
            let fillTransform = positiveSpaceTransform
                .concatenating(CGAffineTransform(scaleX: fillScale, y: fillScale))
                .concatenating(
                    CGAffineTransform(
                        translationX: (renderSize.width - scaledSize.width) / 2.0,
                        y: (renderSize.height - scaledSize.height) / 2.0
                    )
                )
            layerInstruction.setTransform(fillTransform, at: cursor)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
            cursor = cursor + info.duration
        }
        guard cursor.seconds > 0 else { throw WebRtcSessionError.cameraUnavailable }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AI-Camera-Merged-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality) else {
            throw WebRtcSessionError.cameraUnavailable
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                if let error = exportSession.error {
                    continuation.resume(throwing: error)
                } else if exportSession.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WebRtcSessionError.cameraUnavailable)
                }
            }
        }
        segments.forEach { try? FileManager.default.removeItem(at: $0) }
        return outputURL
    }

    private func mergeStandaloneAudioSegments(_ audioSegments: [URL], into videoURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let videoDuration = try await videoAsset.load(.duration)
        let videoTimeRange = CMTimeRange(start: .zero, duration: videoDuration)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw WebRtcSessionError.cameraUnavailable
        }
        try compositionVideoTrack.insertTimeRange(videoTimeRange, of: sourceVideoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = preferredTransform

        if let sourceVideoAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first,
           let compositionSourceAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compositionSourceAudioTrack.insertTimeRange(videoTimeRange, of: sourceVideoAudioTrack, at: .zero)
        }

        if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var cursor = CMTime.zero
            for audioURL in audioSegments {
                let audioAsset = AVURLAsset(url: audioURL)
                let audioDuration = try await audioAsset.load(.duration)
                guard audioDuration.isValid, audioDuration.seconds > 0,
                      let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else { continue }
                let remainingDuration = videoDuration - cursor
                guard remainingDuration.seconds > 0 else { break }
                let insertDuration = min(audioDuration, remainingDuration)
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: insertDuration),
                    of: sourceAudioTrack,
                    at: cursor
                )
                cursor = cursor + insertDuration
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AI-Camera-With-Audio-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality) else {
            throw WebRtcSessionError.cameraUnavailable
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                if let error = exportSession.error {
                    continuation.resume(throwing: error)
                } else if exportSession.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WebRtcSessionError.cameraUnavailable)
                }
            }
        }
        audioSegments.forEach { try? FileManager.default.removeItem(at: $0) }
        try? FileManager.default.removeItem(at: videoURL)
        return outputURL
    }

    private func readyCameraCapturerForRecording() async throws -> RTCCameraVideoCapturer {
        for _ in 0..<18 {
            if let cameraCapturer,
               !isRestartingCapture,
               activeCaptureDevice != nil,
               cameraCapturer.captureSession.isRunning {
                return cameraCapturer
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw WebRtcSessionError.cameraUnavailable
    }

    private func startCapture(
        _ capturer: RTCCameraVideoCapturer,
        lensFacing: LensFacing,
        commitCapturedLensImmediately: Bool = true
    ) throws {
        let profile = streamQualityMode.webRtcProfile.adjusted(for: lensFacing)
        let device = try Self.startCaptureOnCapturer(capturer, lensFacing: lensFacing, profile: profile)
        activeCaptureDevice = device
        activeLensFacing = lensFacing
        publishPreviewSize(profile)
        if commitCapturedLensImmediately {
            capturedLensFacing = lensFacing
        }
        applyDeviceControls(zoomLevel: activeZoomLevel)
        applyExposureOnDevice(device, exposureIndex: activeExposureIndex)
    }

    private func publishPreviewSize(_ profile: WebRtcStreamProfile) {
        guard let roomCode, let repository = repository as? any RoomCameraControlUpdating else { return }
        Task {
            try? await repository.updatePreviewSize(roomCode: roomCode, width: profile.width, height: profile.height)
        }
    }

    private nonisolated static func startCaptureOnCapturer(
        _ capturer: RTCCameraVideoCapturer,
        lensFacing: LensFacing,
        profile: WebRtcStreamProfile
    ) throws -> AVCaptureDevice {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let position: AVCaptureDevice.Position = lensFacing == .back ? .back : .front
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetAspectRatio = Double(profile.width) / Double(profile.height)
        let preferredFormats = formats.sorted { lhs, rhs in
            let lhsSize = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsSize = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsDistance = abs(Int(lhsSize.width) - profile.width) + abs(Int(lhsSize.height) - profile.height)
            let rhsDistance = abs(Int(rhsSize.width) - profile.width) + abs(Int(rhsSize.height) - profile.height)
            let lhsAspectDelta = abs((Double(lhsSize.width) / Double(lhsSize.height)) - targetAspectRatio)
            let rhsAspectDelta = abs((Double(rhsSize.width) / Double(rhsSize.height)) - targetAspectRatio)
            let lhsMaxFPS = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rhsMaxFPS = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let lhsSupportsFPS = lhsMaxFPS >= Double(profile.fps)
            let rhsSupportsFPS = rhsMaxFPS >= Double(profile.fps)
            if lhsSupportsFPS != rhsSupportsFPS {
                return lhsSupportsFPS
            }
            if abs(lhsAspectDelta - rhsAspectDelta) > 0.01 {
                return lhsAspectDelta < rhsAspectDelta
            }
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhsMaxFPS > rhsMaxFPS
        }
        guard let format = preferredFormats.first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let supportedFPS = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max() ?? profile.fps
        capturer.startCapture(with: device, format: format, fps: min(supportedFPS, profile.fps))
        return device
    }

    private nonisolated static func applyDeviceControls(_ device: AVCaptureDevice, zoomLevel: Double) {
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(maxZoom, zoomLevel))
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private nonisolated static func applyExposureOnDevice(_ device: AVCaptureDevice, exposureIndex: Int) {
        do {
            try device.lockForConfiguration()
            let targetBias = Float(exposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias) { _ in }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func applyDeviceControls(zoomLevel: Double) {
        guard let device = activeCaptureDevice else { return }
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(maxZoom, zoomLevel))
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func applyExposureOnDevice(_ device: AVCaptureDevice, exposureIndex: Int) {
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

    private func configureVideoSender(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        let profile = activeWebRtcStreamProfile()
        parameters.encodings.forEach { encoding in
            encoding.minBitrateBps = NSNumber(value: profile.minBitrate)
            encoding.maxBitrateBps = NSNumber(value: profile.maxBitrate)
            encoding.maxFramerate = NSNumber(value: profile.fps)
        }
        sender.parameters = parameters
    }

    private func adaptLocalVideoSource() {
        guard let localVideoSource else { return }
        let profile = activeWebRtcStreamProfile()
        localVideoSource.adaptOutputFormat(toWidth: Int32(profile.width), height: Int32(profile.height), fps: Int32(profile.fps))
    }

    private func activeWebRtcStreamProfile() -> WebRtcStreamProfile {
        let profile = streamQualityMode.webRtcProfile.adjusted(for: activeLensFacing)
        guard isThrottlingLocalStreamForRecording else { return profile }
        return WebRtcStreamProfile(
            width: min(profile.width, 640),
            height: min(profile.height, 360),
            fps: min(profile.fps, 15),
            minBitrate: min(profile.minBitrate, 450_000),
            maxBitrate: min(profile.maxBitrate, 1_200_000)
        )
    }

    private func setLocalStreamThrottledForRecording(_ isThrottled: Bool) {
        guard isThrottlingLocalStreamForRecording != isThrottled else { return }
        isThrottlingLocalStreamForRecording = isThrottled
        if let videoSender {
            configureVideoSender(videoSender)
        }
    }

    private func makeOffer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveVideo": "true"], optionalConstraints: nil)
        return try await peerConnection.offerAsync(for: constraints)
    }

    private func makeAnswer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveVideo": "true"], optionalConstraints: nil)
        return try await peerConnection.answerAsync(for: constraints)
    }

    private func observeSignaling(roomCode: String, repository: any RoomSignalingRepository) {
        signalingTask?.cancel()
        candidatePollingTask?.cancel()
        signalingTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await room in await repository.observeRoom(roomCode: roomCode) {
                    await self.apply(room: room, repository: repository)
                }
            } catch {
                await MainActor.run { self.state = .failed }
            }
        }
        candidatePollingTask = Task { [weak self] in
            guard let self else { return }
            var pollCount = 0
            while !Task.isCancelled {
                await self.applyRemoteCandidates(roomCode: roomCode, repository: repository)
                pollCount += 1
                let delay: Duration
                if pollCount < 80 {
                    delay = .milliseconds(150)
                } else if pollCount < 180 {
                    delay = .milliseconds(500)
                } else {
                    delay = .seconds(2)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func apply(room: RoomDocument, repository: any RoomSignalingRepository) async {
        guard let peerConnection else { return }
        do {
            if role == .host,
               let roomRtcSessionId = room.rtcSessionId,
               let currentSessionId = rtcSessionId,
               roomRtcSessionId != currentSessionId,
               peerConnection.remoteDescription != nil {
                await restartHost(roomCode: room.roomCode, repository: repository)
                return
            }

            if rtcSessionId == nil, let roomRtcSessionId = room.rtcSessionId {
                rtcSessionId = roomRtcSessionId
            }

            if role == .host, room.controllerApproved, peerConnection.remoteDescription == nil, let offerSdp = room.offer {
                try await peerConnection.setRemoteDescriptionAsync(RTCSessionDescription(type: .offer, sdp: offerSdp))
                let answer = try await makeAnswer(on: peerConnection)
                try await peerConnection.setLocalDescriptionAsync(answer)
                let activeSessionId = room.rtcSessionId ?? rtcSessionId ?? UUID().uuidString
                rtcSessionId = activeSessionId
                try await repository.setAnswer(answer.sdp, roomCode: room.roomCode, rtcSessionId: activeSessionId)
                state = .waitingForVideo
            }

            if role == .controller, peerConnection.remoteDescription == nil, let answerSdp = room.answer {
                try await peerConnection.setRemoteDescriptionAsync(RTCSessionDescription(type: .answer, sdp: answerSdp))
                state = remoteVideoTrack == nil ? .waitingForVideo : .connected
            }
        } catch {
            state = .failed
        }
    }

    private func applyRemoteCandidates(roomCode: String, repository: any RoomSignalingRepository) async {
        guard let peerConnection else { return }
        do {
            let candidates = role == .host
                ? try await repository.controllerCandidates(roomCode: roomCode, rtcSessionId: rtcSessionId)
                : try await repository.cameraCandidates(roomCode: roomCode, rtcSessionId: rtcSessionId)
            for payload in candidates where !appliedRemoteCandidateIDs.contains(payload.id) {
                appliedRemoteCandidateIDs.insert(payload.id)
                let candidate = RTCIceCandidate(sdp: payload.candidate, sdpMLineIndex: payload.sdpMLineIndex, sdpMid: payload.sdpMid)
                try await peerConnection.addIceCandidateAsync(candidate)
            }
        } catch {
            // Candidate polling is best-effort; room polling handles fatal signaling failures.
        }
    }

    private func startVideoWatchdog() {
        guard role == .controller else { return }
        streamHealthMonitor.start(
            isActive: { [weak self] in
                self?.role == .controller && self?.state == .connected
            },
            decodedFrames: { [weak self] in
                await self?.decodedVideoFrames()
            },
            onProgress: { [weak self] decodedFrames in
                self?.decodedVideoFrameCount = decodedFrames
            },
            onStall: { [weak self] in
                guard let self, let roomCode = self.roomCode, let repository = self.repository else { return }
                await self.restartController(roomCode: roomCode, repository: repository)
            }
        )
    }

    func retryControllerConnection(roomCode: String, repository: any RoomSignalingRepository) async {
        #if canImport(WebRTC)
        guard role == .controller else { return }
        await restartController(roomCode: roomCode, repository: repository)
        #endif
    }

    private func restartController(roomCode: String, repository: any RoomSignalingRepository) async {
        reconnectCount += 1
        prepareControllerReconnect()
        try? await Task.sleep(for: .milliseconds(150))
        await startController(roomCode: roomCode, repository: repository, preserveRemotePreview: true)
    }

    private func prepareControllerReconnect() {
        #if canImport(WebRTC)
        signalingTask?.cancel()
        signalingTask = nil
        candidatePollingTask?.cancel()
        candidatePollingTask = nil
        streamHealthMonitor.cancel()
        peerConnection?.close()
        peerConnection = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        state = .connecting
        iceConnectionStateDescription = "reconnecting"
        #endif
    }

    private func restartHost(roomCode: String, repository: any RoomSignalingRepository) async {
        reconnectCount += 1
        prepareHostReconnect()
        try? await Task.sleep(for: .milliseconds(100))
        await startHost(roomCode: roomCode, repository: repository, preserveLocalCapture: true)
    }

    private func prepareHostReconnect() {
        #if canImport(WebRTC)
        signalingTask?.cancel()
        signalingTask = nil
        candidatePollingTask?.cancel()
        candidatePollingTask = nil
        streamHealthMonitor.cancel()
        peerConnection?.close()
        peerConnection = nil
        videoSender = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        state = .connecting
        iceConnectionStateDescription = "reconnecting"
        #endif
    }

    private func decodedVideoFrames() async -> Int? {
        guard let peerConnection else { return nil }
        return await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                let framesDecoded = report.statistics.values.compactMap { statistic -> Int? in
                    guard statistic.type == "inbound-rtp" else { return nil }
                    guard (statistic.values["kind"] as? String == "video") || (statistic.values["mediaType"] as? String == "video") else { return nil }
                    if let value = statistic.values["framesDecoded"] as? NSNumber {
                        return value.intValue
                    }
                    if let value = statistic.values["framesReceived"] as? NSNumber {
                        return value.intValue
                    }
                    return nil
                }.max()
                continuation.resume(returning: framesDecoded)
            }
        }
    }
    #endif
}


#if canImport(WebRTC)
extension WebRtcSessionManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            Task { @MainActor in
                self.remoteVideoTrack = track
                self.state = .connected
                self.startVideoWatchdog()
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in self.iceConnectionStateDescription = newState.diagnosticDescription }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            Task { @MainActor in
                self.remoteVideoTrack = track
                self.state = .connected
                self.startVideoWatchdog()
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let roomCode, let repository else { return }
            let activeSessionId = rtcSessionId ?? UUID().uuidString
            rtcSessionId = activeSessionId
            let payload = IceCandidatePayload(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid ?? "0",
                sdpMLineIndex: candidate.sdpMLineIndex
            )
            do {
                if role == .host {
                    try await repository.addCameraCandidate(payload, roomCode: roomCode, rtcSessionId: activeSessionId)
                } else {
                    try await repository.addControllerCandidate(payload, roomCode: roomCode, rtcSessionId: activeSessionId)
                }
            } catch {
                state = .failed
            }
        }
    }
}
#endif
