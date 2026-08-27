import AVFoundation
import CoreImage
import CoreMotion
import Foundation
import UIKit
import Vision

enum NightModeState: Equatable {
    case unavailable
    case suggested(NightModePlan)
    case active(NightModePlan)
    case capturing(NightModePlan, progress: Double)
    case processing(NightModePlan)

    var isAvailable: Bool {
        switch self {
        case .suggested, .active, .capturing, .processing:
            return true
        case .unavailable:
            return false
        }
    }

    var isActive: Bool {
        switch self {
        case .active, .capturing, .processing:
            return true
        case .unavailable, .suggested:
            return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .capturing, .processing:
            return true
        case .unavailable, .suggested, .active:
            return false
        }
    }

    var plan: NightModePlan? {
        switch self {
        case .suggested(let plan), .active(let plan), .capturing(let plan, _), .processing(let plan):
            return plan
        case .unavailable:
            return nil
        }
    }
}

struct NightModePlan: Equatable, Sendable {
    static let previewTreatment = NightModePlan(duration: 1.0, frameCount: 3, frameInterval: 0.33, quality: 0.68)

    let duration: TimeInterval
    let frameCount: Int
    let frameInterval: TimeInterval
    let quality: Double

    var durationLabel: String {
        "\(max(1, Int(duration.rounded())))s"
    }

    func exposureBias(forFrame index: Int) -> Float {
        let bracketPattern: [Double] = [0.0, 0.35, -0.28, 0.52, -0.18]
        let scale = min(1.0, max(0.42, quality))
        return Float(bracketPattern[index % bracketPattern.count] * scale)
    }
}

struct NightModeSceneMetrics: Sendable {
    let exposureDuration: TimeInterval
    let iso: Float
    let exposureTargetOffset: Float
    let isLowLightBoostSupported: Bool
    let isLowLightBoostEnabled: Bool
    let lensFacing: LensFacing
    let deviceType: AVCaptureDevice.DeviceType
    let motionMagnitude: Double

    var lowLightScore: Double {
        let durationScore = min(1.0, max(0.0, (exposureDuration - 0.012) / 0.055))
        let isoScore = min(1.0, max(0.0, (Double(iso) - 420.0) / 900.0))
        let offsetScore = min(1.0, max(0.0, Double(-exposureTargetOffset) / 1.25))
        let boostScore = isLowLightBoostEnabled ? 0.22 : 0.0
        return min(1.0, durationScore * 0.42 + isoScore * 0.36 + offsetScore * 0.22 + boostScore)
    }

    var supportsReliableNightCapture: Bool {
        lensFacing == .back && deviceType != .builtInUltraWideCamera
    }
}

enum NightModePlanner {
    static let enableThreshold = 0.54
    static let disableThreshold = 0.36

    static func plan(for metrics: NightModeSceneMetrics) -> NightModePlan? {
        guard metrics.supportsReliableNightCapture else { return nil }
        let score = metrics.lowLightScore
        guard score >= disableThreshold else { return nil }

        let stabilityBonus = max(0.0, min(1.0, 1.0 - metrics.motionMagnitude / 0.18))
        let rawDuration = 0.9 + (score * 1.15) + (stabilityBonus * score * 0.75)
        let duration = min(metrics.motionMagnitude > 0.22 ? 1.25 : 2.6, max(0.9, rawDuration))
        let frameCount = min(metrics.motionMagnitude > 0.22 ? 3 : 5, max(3, Int((duration * 1.9).rounded())))
        let interval = duration / Double(frameCount)
        return NightModePlan(duration: duration, frameCount: frameCount, frameInterval: interval, quality: score)
    }
}

final class NightModeMotionMonitor {
    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var latestMagnitude = 0.0

    init() {
        queue.name = "night.mode.motion.queue"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.12
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let rotationRate = motion?.rotationRate, let acceleration = motion?.userAcceleration else { return }
            let rotationMagnitude = abs(rotationRate.x) + abs(rotationRate.y) + abs(rotationRate.z)
            let accelerationMagnitude = abs(acceleration.x) + abs(acceleration.y) + abs(acceleration.z)
            self.lock.lock()
            self.latestMagnitude = min(1.0, rotationMagnitude * 0.12 + accelerationMagnitude * 0.55)
            self.lock.unlock()
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    func currentMagnitude() -> Double {
        lock.lock()
        let magnitude = latestMagnitude
        lock.unlock()
        return magnitude
    }
}

struct NightModePhotoProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func process(frames: [UIImage], plan: NightModePlan, aspectRatio: CameraAspectRatio) -> (image: UIImage, data: Data)? {
        let normalizedFrames = frames.map { $0.cropped(to: aspectRatio).normalizedForSaving() }
        guard let first = normalizedFrames.first, let firstCI = CIImage(image: first) else { return nil }
        let targetExtent = firstCI.extent
        let ciFrames = normalizedFrames.compactMap { CIImage(image: $0)?.cropped(to: targetExtent) }
        guard !ciFrames.isEmpty else { return nil }

        let referenceIndex = sharpestFrameIndex(in: ciFrames)
        let reference = ciFrames[referenceIndex].cropped(to: targetExtent)
        let alignedSupportFrames = alignedFrames(to: reference, from: ciFrames, excluding: referenceIndex, targetExtent: targetExtent)
            .sorted { sharpnessScore($0) > sharpnessScore($1) }
        let supportFrames = alignedSupportFrames.isEmpty ? [] : Array(alignedSupportFrames.prefix(1))
        let supportBlend = conservativeMerge(reference: reference, supportFrames: supportFrames, quality: plan.quality)

        let toneMapped = supportBlend
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.00),
                "inputPoint1": CIVector(x: 0.14, y: 0.08),
                "inputPoint2": CIVector(x: 0.46, y: 0.53),
                "inputPoint3": CIVector(x: 0.84, y: 0.88),
                "inputPoint4": CIVector(x: 1.00, y: 1.00)
            ])
            .cropped(to: targetExtent)

        let clean = toneMapped
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.008, "inputSharpness": 0.74])
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1.0,
                "inputContrast": 1.12,
                "inputBrightness": -0.004
            ])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.38])
            .cropped(to: targetExtent)

        let referenceDetail = reference
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1.0,
                "inputContrast": 1.06,
                "inputBrightness": 0.0
            ])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.24])
            .cropped(to: targetExtent)
        let processed = blend(referenceDetail, over: clean, alpha: min(0.20, max(0.10, plan.quality * 0.16)))
            .cropped(to: targetExtent)

        guard let cgImage = context.createCGImage(processed, from: targetExtent) else { return nil }
        let image = UIImage(cgImage: cgImage, scale: first.scale, orientation: .up)
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        return (image, data)
    }

    private func sharpestFrameIndex(in frames: [CIImage]) -> Int {
        frames.indices.max { sharpnessScore(frames[$0]) < sharpnessScore(frames[$1]) } ?? 0
    }

    private func sharpnessScore(_ image: CIImage) -> Double {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return 0 }

        let edges = image
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.0])
            .applyingFilter("CIEdges", parameters: ["inputIntensity": 1.0])
        let average = edges.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3.0
    }

    private func alignedFrames(to reference: CIImage, from frames: [CIImage], excluding referenceIndex: Int, targetExtent: CGRect) -> [CIImage] {
        guard let referenceCGImage = context.createCGImage(reference, from: targetExtent) else { return [] }

        return frames.enumerated().compactMap { index, frame in
            guard index != referenceIndex,
                  let frameCGImage = context.createCGImage(frame, from: targetExtent),
                  let transform = translationTransform(from: frameCGImage, to: referenceCGImage, targetExtent: targetExtent) else {
                return nil
            }

            return frame
                .transformed(by: transform)
                .cropped(to: targetExtent)
        }
    }

    private func translationTransform(from image: CGImage, to reference: CGImage, targetExtent: CGRect) -> CGAffineTransform? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: reference)
        let handler = VNImageRequestHandler(cgImage: image)

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let transform = observation.alignmentTransform
        let maxShift = min(targetExtent.width, targetExtent.height) * 0.045
        guard abs(transform.tx) <= maxShift, abs(transform.ty) <= maxShift else { return nil }
        return transform
    }

    private func conservativeMerge(reference: CIImage, supportFrames: [CIImage], quality: Double) -> CIImage {
        guard !supportFrames.isEmpty else { return reference }

        let totalSupportAlpha = min(0.14, max(0.06, quality * 0.11))
        let perFrameAlpha = totalSupportAlpha / Double(supportFrames.count)
        return supportFrames.reduce(reference) { merged, supportFrame in
            blend(supportFrame, over: merged, alpha: perFrameAlpha)
                .cropped(to: reference.extent)
        }
    }

    private func average(_ frames: [CIImage]) -> CIImage {
        guard let first = frames.first else { return CIImage.empty() }
        var accumulator = weightedImage(first, weight: 1.0 / Double(frames.count))
        for frame in frames.dropFirst() {
            accumulator = weightedImage(frame, weight: 1.0 / Double(frames.count))
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: accumulator])
        }
        return accumulator
    }

    private func blend(_ foreground: CIImage, over background: CIImage, alpha: Double) -> CIImage {
        foreground
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
            .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: background])
    }

    private func weightedImage(_ image: CIImage, weight: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }
}
