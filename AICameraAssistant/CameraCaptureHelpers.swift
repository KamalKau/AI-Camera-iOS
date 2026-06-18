@preconcurrency import AVFoundation
import CoreImage
import CoreMotion
import ImageIO
import UIKit

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
}

func configurePhotoConnection(_ photoOutput: AVCapturePhotoOutput, lensFacing: LensFacing) {
    guard let connection = photoOutput.connection(with: .video) else { return }
    if connection.isVideoOrientationSupported {
        connection.videoOrientation = currentCaptureVideoOrientation()
    }
    if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = lensFacing == .front
    }
}

func currentCaptureVideoOrientation() -> AVCaptureVideoOrientation {
    switch currentDeviceCaptureOrientation() {
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
