@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

nonisolated enum BoomerangState: Equatable {
    case idle
    case capturing
    case processing
    case previewing
    case failed(String)
}

final class BoomerangCaptureManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var state: BoomerangState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var saveMessage: String?

    private let captureQueue = DispatchQueue(label: "com.aicameraassistant.boomerang.capture", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "boomerang.processing.queue", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let fileManager = FileManager.default
    private let videoExporter: BoomerangVideoExporting
    private let photoLibrarySaver: BoomerangPhotoLibrarySaving

    private var isInstalled = false
    private var isCapturingFrames = false
    private var isFinishingCapture = false
    private var capturedFrames: [BoomerangCapturedFrame] = []
    private var firstPresentationTime: CMTime?
    private var captureTimer: DispatchSourceTimer?
    private var currentOutputURL: URL?
    private var capturedLensFacing: LensFacing = .back
    private var activeOrientation: AVCaptureVideoOrientation = .portrait

    var isBusy: Bool {
        switch state {
        case .capturing, .processing:
            return true
        default:
            return false
        }
    }

    init(
        videoExporter: BoomerangVideoExporting = DefaultBoomerangVideoExporter(),
        photoLibrarySaver: BoomerangPhotoLibrarySaving = DefaultBoomerangPhotoLibrarySaver()
    ) {
        self.videoExporter = videoExporter
        self.photoLibrarySaver = photoLibrarySaver
        super.init()
    }

    func installVideoOutputIfNeeded(on session: AVCaptureSession, lensFacing: LensFacing) {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            isInstalled = true
        } else if session.outputs.contains(videoOutput) {
            isInstalled = true
        }

        updateConnection(lensFacing: lensFacing)
    }

    func updateConnection(lensFacing: LensFacing) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let orientation = AVCaptureVideoOrientation.currentBoomerangOrientation()
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = lensFacing == .front
        }
        activeOrientation = orientation
    }

    func startCapture(lensFacing: LensFacing) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.isInstalled else {
                self.publishFailure("Boomerang camera output is not ready.")
                return
            }
            guard !self.isCapturingFrames, !self.isFinishingCapture else { return }
            switch self.state {
            case .idle, .failed:
                break
            case .previewing:
                self.removeOutputFileIfNeeded()
            case .capturing, .processing:
                return
            }

            self.removeOutputFileIfNeeded()
            DispatchQueue.main.async {
                self.saveMessage = nil
            }
            self.capturedLensFacing = lensFacing
            self.updateConnection(lensFacing: lensFacing)
            self.capturedFrames.removeAll(keepingCapacity: true)
            self.firstPresentationTime = nil
            self.isCapturingFrames = true
            self.isFinishingCapture = false
            self.publishState(.capturing, progress: 0)
            self.debugLog("Capture started")
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            self.startSafetyTimeoutTimer()
        }
    }

    func retake() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked(removeOutput: true)
            self.publishState(.idle, progress: 0)
        }
    }

    func cancel() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked(removeOutput: true)
            self.publishState(.idle, progress: 0)
        }
    }

    func saveToPhotos() async -> String {
        guard let outputURL else { return "No Boomerang is ready to save." }
        return await photoLibrarySaver.saveBoomerang(at: outputURL)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        guard isCapturingFrames, !isFinishingCapture else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            debugLog("First frame received")
            startSafetyTimeoutTimer()
        }
        guard let firstPresentationTime else { return }

        let relativeTime = CMTimeSubtract(presentationTime, firstPresentationTime)
        let elapsed = max(0, CMTimeGetSeconds(relativeTime))
        capturedFrames.append(BoomerangCapturedFrame(pixelBuffer: pixelBuffer, relativeTime: relativeTime))

        if capturedFrames.count == 1 || capturedFrames.count % 8 == 0 {
            debugLog("Captured frame count: \(capturedFrames.count)")
            debugLog(String(format: "Capture elapsed time: %.3f", elapsed))
        }
        publishProgress(min(1.0, elapsed / BoomerangCaptureDefaults.captureDurationSeconds))

        if capturedFrames.count >= BoomerangCaptureDefaults.maxSourceFrames {
            finishCaptureLocked()
            return
        }
        if elapsed >= BoomerangCaptureDefaults.captureDurationSeconds,
           capturedFrames.count >= BoomerangCaptureDefaults.preferredMinimumSourceFrames {
            finishCaptureLocked()
            return
        }
        if elapsed >= BoomerangCaptureDefaults.maxCaptureDurationSeconds,
           capturedFrames.count >= BoomerangCaptureDefaults.minimumSourceFrames {
            finishCaptureLocked()
        }
    }

    private func startSafetyTimeoutTimer() {
        captureTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + BoomerangCaptureDefaults.safetyTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.capturedFrames.isEmpty {
                self.publishFailure("Boomerang failed: camera frames did not start.")
            } else {
                self.finishCaptureLocked()
            }
        }
        captureTimer = timer
        timer.resume()
    }

    private func finishCaptureLocked() {
        guard isCapturingFrames, !isFinishingCapture else { return }
        isCapturingFrames = false
        isFinishingCapture = true
        captureTimer?.cancel()
        captureTimer = nil
        let frames = capturedFrames
        capturedFrames.removeAll(keepingCapacity: true)
        debugLog("Capture completed with \(frames.count) frames")
        publishState(.processing, progress: 1)
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                let url = try self.videoExporter.exportBoomerang(frames: frames)
                self.captureQueue.async {
                    self.currentOutputURL = url
                    self.isFinishingCapture = false
                    DispatchQueue.main.async {
                        self.outputURL = url
                    }
                    self.autoSaveExportedBoomerang(at: url)
                }
            } catch {
                self.captureQueue.async {
                    self.isFinishingCapture = false
                    self.publishFailure("Boomerang failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelLocked(removeOutput: Bool) {
        isCapturingFrames = false
        isFinishingCapture = false
        captureTimer?.cancel()
        captureTimer = nil
        capturedFrames.removeAll(keepingCapacity: true)
        firstPresentationTime = nil
        if removeOutput {
            removeOutputFileIfNeeded()
        }
    }

    nonisolated static func forwardReverseFrameOrder(frameCount: Int, cycles: Int) -> [Int] {
        BoomerangFrameSequencer.forwardReverseFrameOrder(frameCount: frameCount, cycles: cycles)
    }

    nonisolated static func presentationTimes(frameCount: Int, frameRate: Int) -> [CMTime] {
        BoomerangFrameSequencer.presentationTimes(frameCount: frameCount, frameRate: frameRate)
    }

    private func removeOutputFileIfNeeded() {
        if let currentOutputURL {
            try? fileManager.removeItem(at: currentOutputURL)
        }
        currentOutputURL = nil
        DispatchQueue.main.async { [weak self] in
            self?.outputURL = nil
        }
    }

    private func copyPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        var copiedBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes, &copiedBuffer) == kCVReturnSuccess,
              let copiedBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(copiedBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copiedBuffer, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount == 0 {
            guard let source = CVPixelBufferGetBaseAddress(pixelBuffer), let destination = CVPixelBufferGetBaseAddress(copiedBuffer) else { return nil }
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(copiedBuffer)
            for row in 0..<height {
                memcpy(destination.advanced(by: row * destinationBytesPerRow), source.advanced(by: row * sourceBytesPerRow), min(sourceBytesPerRow, destinationBytesPerRow))
            }
        } else {
            for plane in 0..<planeCount {
                guard let source = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane),
                      let destination = CVPixelBufferGetBaseAddressOfPlane(copiedBuffer, plane) else { return nil }
                let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(copiedBuffer, plane)
                for row in 0..<planeHeight {
                    memcpy(destination.advanced(by: row * destinationBytesPerRow), source.advanced(by: row * sourceBytesPerRow), min(sourceBytesPerRow, destinationBytesPerRow))
                }
            }
        }
        return copiedBuffer
    }

    private func publishState(_ nextState: BoomerangState, progress nextProgress: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = nextState
            if let nextProgress { self.progress = nextProgress }
            if case .failed(let message) = nextState {
                self.errorMessage = message
            } else {
                self.errorMessage = nil
            }
        }
    }

    private func publishProgress(_ nextProgress: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.progress = nextProgress
        }
    }

    private func publishFailure(_ message: String) {
        cancelLocked(removeOutput: true)
        debugLog(message)
        publishState(.failed(message), progress: 0)
    }

    private func autoSaveExportedBoomerang(at url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let message = await self.photoLibrarySaver.saveBoomerang(at: url)
            await MainActor.run {
                self.saveMessage = message
            }
            self.captureQueue.async {
                self.removeOutputFileIfNeeded()
                self.publishState(.idle, progress: 0)
            }
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[Boomerang] \(message)")
        #endif
    }
}

struct BoomerangPreviewScreen: View {
    @ObservedObject var manager: BoomerangCaptureManager
    let onRetake: () -> Void

    var body: some View {
        ZStack {
            if let url = manager.outputURL {
                BoomerangLoopingPlayerView(url: url)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
            }

            VStack {
                HStack {
                    Button(action: onRetake) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.38), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)

                Spacer()
            }
        }
    }
}

private struct BoomerangLoopingPlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerContainerView {
        let view = LoopingPlayerContainerView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: LoopingPlayerContainerView, context: Context) {
        uiView.configure(url: url)
    }

    static func dismantleUIView(_ uiView: LoopingPlayerContainerView, coordinator: ()) {
        uiView.stop()
    }
}

private final class LoopingPlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    func configure(url: URL) {
        guard currentURL != url else { return }
        stop()
        currentURL = url
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = queuePlayer
        player = queuePlayer
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    func stop() {
        player?.pause()
        playerLayer.player = nil
        looper = nil
        player = nil
        currentURL = nil
    }
}

private extension AVCaptureVideoOrientation {
    static func currentBoomerangOrientation() -> AVCaptureVideoOrientation {
        switch currentInterfaceCaptureOrientation() {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
}
