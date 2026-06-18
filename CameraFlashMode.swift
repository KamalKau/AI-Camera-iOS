@preconcurrency import AVFoundation
import Foundation

extension String {
    var safeCameraFlashMode: String {
        ["off", "auto", "on"].contains(self) ? self : "off"
    }

    var nextCameraFlashMode: String {
        switch safeCameraFlashMode {
        case "off": return "auto"
        case "auto": return "on"
        default: return "off"
        }
    }

    var cameraFlashLabel: String {
        switch safeCameraFlashMode {
        case "auto": return "Flash Auto"
        case "on": return "Flash On"
        default: return "Flash Off"
        }
    }

    var cameraFlashIconName: String {
        switch safeCameraFlashMode {
        case "auto": return "bolt"
        case "on": return "bolt.fill"
        default: return "bolt.slash"
        }
    }

    func avCaptureFlashMode(supportedModes: [AVCaptureDevice.FlashMode], lensFacing: LensFacing) -> AVCaptureDevice.FlashMode? {
        let requestedMode: AVCaptureDevice.FlashMode
        switch safeCameraFlashMode {
        case "auto":
            requestedMode = lensFacing == .front ? .off : .auto
        case "on":
            requestedMode = .on
        default:
            requestedMode = .off
        }
        if supportedModes.contains(requestedMode) {
            return requestedMode
        }
        return supportedModes.contains(.off) ? .off : nil
    }

    func avCaptureFlashMode(supportedModes: [AVCaptureDevice.FlashMode]) -> AVCaptureDevice.FlashMode? {
        avCaptureFlashMode(supportedModes: supportedModes, lensFacing: .back)
    }
}
