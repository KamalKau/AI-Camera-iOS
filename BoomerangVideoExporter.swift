import AVFoundation
import Foundation

final class BoomerangCapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let relativeTime: CMTime

    init(pixelBuffer: CVPixelBuffer, relativeTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.relativeTime = relativeTime
    }
}

protocol BoomerangVideoExporting {
    func exportBoomerang(frames: [BoomerangCapturedFrame]) throws -> URL
}

enum BoomerangFrameSequencer {
    nonisolated static func normalizedFrames(from frames: [BoomerangCapturedFrame], targetCount: Int) -> [BoomerangCapturedFrame] {
        guard !frames.isEmpty, targetCount > 0 else { return [] }
        guard frames.count < targetCount else { return frames }
        guard targetCount > 1, frames.count > 1 else {
            return Array(repeating: frames[0], count: targetCount)
        }

        return (0..<targetCount).map { index in
            let sourcePosition = Double(index) * Double(frames.count - 1) / Double(targetCount - 1)
            let sourceIndex = min(frames.count - 1, max(0, Int(sourcePosition.rounded())))
            return frames[sourceIndex]
        }
    }

    nonisolated static func forwardReverseFrameOrder(frameCount: Int, cycles: Int) -> [Int] {
        guard frameCount >= 2, cycles > 0 else { return [] }
        let forward = Array(0..<frameCount)
        let reverse = frameCount > 2 ? Array(1..<(frameCount - 1)).reversed() : []
        let cycle = forward + reverse
        return Array(repeating: cycle, count: cycles).flatMap { $0 }
    }

    nonisolated static func presentationTimes(frameCount: Int, frameRate: Int) -> [CMTime] {
        guard frameCount > 0, frameRate > 0 else { return [] }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        return (0..<frameCount).map { CMTimeMultiply(duration, multiplier: Int32($0)) }
    }
}

enum BoomerangCaptureError: LocalizedError {
    case insufficientFrames
    case writerSetupFailed
    case writerAppendFailed
    case writerFinishFailed
    case writerTimedOut

    var errorDescription: String? {
        switch self {
        case .insufficientFrames:
            return "Not enough video frames were captured. Please try again."
        case .writerSetupFailed:
            return "The video writer could not start."
        case .writerAppendFailed:
            return "A frame could not be written."
        case .writerFinishFailed:
            return "The video could not be finalized."
        case .writerTimedOut:
            return "The video took too long to create. Please try again."
        }
    }
}

final class DefaultBoomerangVideoExporter: BoomerangVideoExporting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func exportBoomerang(frames: [BoomerangCapturedFrame]) throws -> URL {
        guard frames.count >= BoomerangCaptureDefaults.minimumSourceFrames else {
            throw BoomerangCaptureError.insufficientFrames
        }

        let sourceFrames = frames.count < BoomerangCaptureDefaults.normalizedSourceFrameCount
            ? BoomerangFrameSequencer.normalizedFrames(from: frames, targetCount: BoomerangCaptureDefaults.normalizedSourceFrameCount)
            : frames
        let frameOrder = BoomerangFrameSequencer.forwardReverseFrameOrder(
            frameCount: sourceFrames.count,
            cycles: BoomerangCaptureDefaults.exportCycleCount
        )
        guard !frameOrder.isEmpty else { throw BoomerangCaptureError.insufficientFrames }

        let firstBuffer = sourceFrames[0].pixelBuffer
        let width = CVPixelBufferGetWidth(firstBuffer)
        let height = CVPixelBufferGetHeight(firstBuffer)
        let outputURL = try makeOutputURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 4, 2_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else { throw BoomerangCaptureError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? BoomerangCaptureError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(BoomerangCaptureDefaults.targetFrameRate))
        var frameIndex = 0
        for sourceIndex in frameOrder {
            let readyDeadline = Date().addingTimeInterval(2.0)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || writer.status == .cancelled {
                    throw writer.error ?? BoomerangCaptureError.writerAppendFailed
                }
                if Date() >= readyDeadline {
                    writer.cancelWriting()
                    throw BoomerangCaptureError.writerTimedOut
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            guard adaptor.append(sourceFrames[sourceIndex].pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? BoomerangCaptureError.writerAppendFailed
            }
            frameIndex += 1
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 5.0) == .success else {
            writer.cancelWriting()
            try? fileManager.removeItem(at: outputURL)
            throw BoomerangCaptureError.writerTimedOut
        }

        guard writer.status == .completed else {
            try? fileManager.removeItem(at: outputURL)
            throw writer.error ?? BoomerangCaptureError.writerFinishFailed
        }
        return outputURL
    }

    private func makeOutputURL() throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent("Boomerang", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("boomerang-\(UUID().uuidString).mp4")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return url
    }
}
