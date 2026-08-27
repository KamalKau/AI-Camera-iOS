@preconcurrency import AVFoundation
import CoreImage
import CoreMotion
import ImageIO
import UIKit

enum CameraAspectRatio: String, CaseIterable, Sendable {
    case full
    case ratio9x16 = "9_16"
    case ratio3x4 = "3_4"
    case square = "1_1"

    var next: CameraAspectRatio {
        let allCases = Self.allCases
        guard let index = allCases.firstIndex(of: self) else { return .full }
        return allCases[(index + 1) % allCases.count]
    }

    var label: String {
        switch self {
        case .full: return "Full"
        case .ratio9x16: return "9:16"
        case .ratio3x4: return "3:4"
        case .square: return "1:1"
        }
    }

    var aspectValue: CGFloat? {
        switch self {
        case .full: return nil
        case .ratio9x16: return 9.0 / 16.0
        case .ratio3x4: return 3.0 / 4.0
        case .square: return 1.0
        }
    }

    init(roomValue: String) {
        self = Self(rawValue: roomValue) ?? .full
    }
}

enum CameraDeviceControls {
    nonisolated static func applyZoom(to device: AVCaptureDevice, zoomLevel: Double) {
        do {
            try device.lockForConfiguration()
            let maxZoom = device.activeFormat.videoMaxZoomFactor
            let targetZoom = zoomFactor(for: zoomLevel, device: device, maxZoom: maxZoom)
            let delta = abs(device.videoZoomFactor - targetZoom)
            if delta > 0.35 {
                device.ramp(toVideoZoomFactor: targetZoom, withRate: 16.0)
            } else {
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                device.videoZoomFactor = targetZoom
            }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    nonisolated static func applyExposure(to device: AVCaptureDevice, exposureIndex: Int) {
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

    nonisolated static func applyLowLightBoost(to device: AVCaptureDevice, enabled: Bool) {
        guard device.isLowLightBoostSupported else { return }
        do {
            try device.lockForConfiguration()
            device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    nonisolated static func applyExposureBias(to device: AVCaptureDevice, bias: Float) {
        do {
            try device.lockForConfiguration()
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, bias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    nonisolated static func applyNightModePreview(to device: AVCaptureDevice, enabled: Bool, quality: Double, exposureIndex: Int) {
        do {
            try device.lockForConfiguration()
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = enabled
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            let userBias = Float(min(8, max(-8, exposureIndex))) / 2.0
            let previewBias: Float
            if enabled {
                let normalizedQuality = min(1.0, max(0.0, quality))
                previewBias = userBias + Float(0.35 + normalizedQuality * 0.25)
            } else {
                previewBias = userBias
            }
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, previewBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    nonisolated static func zoomFactor(for displayZoomLevel: Double, device: AVCaptureDevice, maxZoom: CGFloat) -> CGFloat {
        let requestedZoom = max(0.5, min(8.0, displayZoomLevel))
        let mappedZoom = device.deviceType == .builtInUltraWideCamera
            ? requestedZoom / 0.5
            : requestedZoom
        let minZoom = max(1.0, device.minAvailableVideoZoomFactor)
        return max(minZoom, min(maxZoom, CGFloat(mappedZoom)))
    }
}

enum CameraBackDeviceSelection {
    nonisolated static func preferredDevice(from devices: [AVCaptureDevice] = [], zoomLevel: Double) -> AVCaptureDevice? {
        if zoomLevel < 1.0, let ultraWideDevice = physicalUltraWideDevice(from: devices) {
            return ultraWideDevice
        }

        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]

        for deviceType in preferredTypes {
            if let device = devices.first(where: { $0.position == .back && $0.deviceType == deviceType }) {
                return device
            }
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) {
                return device
            }
        }

        return devices.first(where: { $0.position == .back })
    }

    nonisolated static func effectiveZoomLevel(lensFacing: LensFacing, requestedZoomLevel: Double, devices: [AVCaptureDevice] = []) -> Double {
        let maximumZoom = 8.0
        guard lensFacing == .back else {
            return max(1.0, min(maximumZoom, requestedZoomLevel))
        }
        let minimumZoom = physicalUltraWideDevice(from: devices) == nil ? 1.0 : 0.5
        return max(minimumZoom, min(maximumZoom, requestedZoomLevel))
    }

    nonisolated static func isPreferred(_ device: AVCaptureDevice, zoomLevel: Double) -> Bool {
        guard device.position == .back else { return false }
        if zoomLevel < 1.0 {
            return device.deviceType == .builtInUltraWideCamera
        }
        if isVirtualBackCamera(device) {
            return true
        }
        return device.deviceType == .builtInWideAngleCamera
    }

    private nonisolated static func physicalUltraWideDevice(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let device = devices.first(where: { $0.position == .back && $0.deviceType == .builtInUltraWideCamera }) {
            return device
        }
        return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    }

    private nonisolated static func isVirtualBackCamera(_ device: AVCaptureDevice) -> Bool {
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera:
            return true
        default:
            return false
        }
    }
}

extension UIImage {
    func normalizedForPortraitProcessing() -> UIImage {
        normalizedForSaving()
    }

    func normalizedForSaving() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func cropped(to aspectRatio: CameraAspectRatio) -> UIImage {
        guard let targetAspect = aspectRatio.aspectValue else { return normalizedForSaving() }
        let sourceImage = normalizedForSaving()
        let sourceSize = sourceImage.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return sourceImage }

        let sourceAspect = sourceSize.width / sourceSize.height
        let cropSize: CGSize
        if sourceAspect > targetAspect {
            cropSize = CGSize(width: sourceSize.height * targetAspect, height: sourceSize.height)
        } else {
            cropSize = CGSize(width: sourceSize.width, height: sourceSize.width / targetAspect)
        }

        let cropRect = CGRect(
            x: (sourceSize.width - cropSize.width) / 2.0,
            y: (sourceSize.height - cropSize.height) / 2.0,
            width: cropSize.width,
            height: cropSize.height
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: cropSize, format: format).image { _ in
            sourceImage.draw(
                in: CGRect(
                    x: -cropRect.minX,
                    y: -cropRect.minY,
                    width: sourceSize.width,
                    height: sourceSize.height
                )
            )
        }
    }

    func jpegData(aspectRatio: CameraAspectRatio, compressionQuality: CGFloat = 0.94) -> Data? {
        cropped(to: aspectRatio).jpegData(compressionQuality: compressionQuality)
    }
}

func configurePhotoConnection(_ photoOutput: AVCapturePhotoOutput, lensFacing: LensFacing) {
    configureCaptureConnection(photoOutput.connection(with: .video), lensFacing: lensFacing)
}

func configureMovieConnection(_ movieOutput: AVCaptureMovieFileOutput, lensFacing: LensFacing) {
    configureCaptureConnection(
        movieOutput.connection(with: .video),
        lensFacing: lensFacing,
        mirrorsFrontCamera: false,
        videoOrientation: currentInterfaceCaptureVideoOrientation() ?? currentCaptureVideoOrientation()
    )
}


private func configureCaptureConnection(
    _ connection: AVCaptureConnection?,
    lensFacing: LensFacing,
    mirrorsFrontCamera: Bool = true,
    videoOrientation: AVCaptureVideoOrientation? = nil
) {
    guard let connection else { return }
    if connection.isVideoOrientationSupported {
        connection.videoOrientation = videoOrientation ?? currentCaptureVideoOrientation()
    }
    if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrorsFrontCamera && lensFacing == .front
    }
}

func currentCaptureVideoOrientation() -> AVCaptureVideoOrientation {
    captureVideoOrientation(for: currentDeviceCaptureOrientation())
}

func currentInterfaceCaptureVideoOrientation() -> AVCaptureVideoOrientation? {
    currentInterfaceCaptureOrientation().map(captureVideoOrientation(for:))
}

private func captureVideoOrientation(for orientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
    switch orientation {
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

func shouldUseLandscapeCanvas(photoOutput: AVCapturePhotoOutput, capturedDeviceOrientation: UIDeviceOrientation) -> Bool {
    capturedDeviceOrientation.isLandscape
        || photoOutput.connection(with: .video)?.videoOrientation.isLandscapeCapture == true
        || currentInterfaceCaptureOrientation()?.isLandscape == true
}

func currentDeviceCaptureOrientation() -> UIDeviceOrientation {
    DeviceOrientationTracker.shared.currentOrientation()
}

func currentInterfaceCaptureOrientation() -> UIDeviceOrientation? {
    let orientation = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .interfaceOrientation

    switch orientation {
    case .landscapeLeft:
        return .landscapeLeft
    case .landscapeRight:
        return .landscapeRight
    case .portrait:
        return .portrait
    case .portraitUpsideDown:
        return .portraitUpsideDown
    default:
        return nil
    }
}

extension AVCaptureVideoOrientation {
    var isLandscapeCapture: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }
}

final class DeviceOrientationTracker: NSObject {
    static let shared = DeviceOrientationTracker()

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let lock = NSLock()
    private var lastValidOrientation: UIDeviceOrientation = .portrait
    private var hasMotionOrientation = false

    private override init() {
        super.init()
        motionQueue.name = "camera.orientation.tracker.queue"
        motionQueue.qualityOfService = .utility
        motionQueue.maxConcurrentOperationCount = 1
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateOrientation(UIDevice.current.orientation)
        startMotionUpdates()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    func currentOrientation() -> UIDeviceOrientation {
        lock.lock()
        let shouldUseDeviceOrientation = !hasMotionOrientation
        let orientation = lastValidOrientation
        lock.unlock()

        if shouldUseDeviceOrientation {
            updateOrientation(UIDevice.current.orientation)
            lock.lock()
            let updatedOrientation = lastValidOrientation
            lock.unlock()
            return updatedOrientation
        }
        return orientation
    }

    @objc private func deviceOrientationDidChange() {
        lock.lock()
        let shouldUseDeviceOrientation = !hasMotionOrientation
        lock.unlock()
        guard shouldUseDeviceOrientation else { return }
        updateOrientation(UIDevice.current.orientation)
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.25
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            self.updateOrientationFromGravity(x: gravity.x, y: gravity.y)
        }
    }

    private func updateOrientationFromGravity(x: Double, y: Double) {
        let horizontalMagnitude = abs(x)
        let verticalMagnitude = abs(y)
        guard max(horizontalMagnitude, verticalMagnitude) > 0.45 else { return }
        let orientation: UIDeviceOrientation = if horizontalMagnitude > verticalMagnitude {
            x > 0 ? .landscapeRight : .landscapeLeft
        } else {
            y > 0 ? .portraitUpsideDown : .portrait
        }
        lock.lock()
        hasMotionOrientation = true
        lastValidOrientation = orientation
        lock.unlock()
    }

    private func updateOrientation(_ orientation: UIDeviceOrientation) {
        guard orientation.isLandscape || orientation.isPortrait else { return }
        lock.lock()
        lastValidOrientation = orientation
        lock.unlock()
    }
}

struct PhotoCaptureDiagnostics {
    let photoWidth: Int32
    let photoHeight: Int32
    let metadataOrientation: UInt32?
    let imageOrientation: UIImage.Orientation?
    let storedLandscape: Bool
    let portraitMask: CIImage?
}

final class BracketedPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: ([UIImage]) -> Void
    private var images: [UIImage] = []
    private var didComplete = false

    init(completion: @escaping ([UIImage]) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        images.append(image)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        completion(error == nil ? images : [])
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?, Data?, PhotoCaptureDiagnostics) -> Void

    init(completion: @escaping (UIImage?, Data?, PhotoCaptureDiagnostics) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            completion(nil, nil, PhotoCaptureDiagnostics(
                photoWidth: 0,
                photoHeight: 0,
                metadataOrientation: nil,
                imageOrientation: nil,
                storedLandscape: false,
                portraitMask: nil
            ))
            return
        }
        let diagnostics = Self.diagnostics(for: photo)
        completion(nil, data, diagnostics)
    }

    private static func diagnostics(for photo: AVCapturePhoto) -> PhotoCaptureDiagnostics {
        let dimensions = photo.resolvedSettings.photoDimensions
        let orientationValue = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32
        return PhotoCaptureDiagnostics(
            photoWidth: dimensions.width,
            photoHeight: dimensions.height,
            metadataOrientation: orientationValue,
            imageOrientation: nil,
            storedLandscape: isStoredLandscape(width: dimensions.width, height: dimensions.height, orientationValue: orientationValue),
            portraitMask: portraitMask(for: photo, orientationValue: orientationValue)
        )
    }

    private static func portraitMask(for photo: AVCapturePhoto, orientationValue: UInt32?) -> CIImage? {
        guard let matte = photo.portraitEffectsMatte else { return nil }
        let orientedMatte: AVPortraitEffectsMatte
        if let orientationValue, let orientation = CGImagePropertyOrientation(rawValue: orientationValue) {
            orientedMatte = matte.applyingExifOrientation(orientation)
        } else {
            orientedMatte = matte
        }
        return CIImage(cvPixelBuffer: orientedMatte.mattingImage)
    }

    private static func isStoredLandscape(width: Int32, height: Int32, orientationValue: UInt32?) -> Bool {
        guard width > height else { return false }
        guard let orientation = orientationValue.flatMap(CGImagePropertyOrientation.init(rawValue:)) else {
            return true
        }
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return false
        default:
            return true
        }
    }
}

final class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let completion: (URL?, Error?) -> Void

    init(completion: @escaping (URL?, Error?) -> Void) {
        self.completion = completion
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        completion(error == nil ? outputFileURL : nil, error)
    }
}
