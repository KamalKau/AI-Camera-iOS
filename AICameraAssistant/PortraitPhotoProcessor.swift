import CoreImage
import ImageIO
import UIKit
import Vision

struct PortraitPhotoProcessor {
    private let ciContext = CIContext()

    func makePortraitJPEGData(from image: UIImage, effect: String, strength: Int, nativeMask: CIImage?) -> (data: Data, source: String)? {
        let normalizedImage = image.normalizedForPortraitProcessing()
        guard let cgImage = normalizedImage.cgImage else { return nil }
        let inputImage = CIImage(cgImage: cgImage)
        let extent = inputImage.extent
        let clampedStrength = max(1, min(7, strength))

        let maskCandidate: (mask: CIImage, source: String)?
        if let nativeMask = scaledPortraitMask(nativeMask, to: extent), isUsablePortraitMask(nativeMask, extent: extent) {
            maskCandidate = (nativeMask, "native matte")
        } else if let personMask = makePersonSegmentationMask(for: inputImage, orientation: .up), isUsablePortraitMask(personMask, extent: extent) {
            maskCandidate = (personMask, "person segmentation")
        } else if let faceMask = makeFacePortraitMask(for: inputImage, orientation: .up), isUsablePortraitMask(faceMask, extent: extent) {
            maskCandidate = (faceMask, "face fallback")
        } else if let saliencyMask = makeSaliencyPortraitMask(for: inputImage, orientation: .up), isUsablePortraitMask(saliencyMask, extent: extent) {
            maskCandidate = (saliencyMask, "object saliency")
        } else {
            return nil
        }
        guard let maskCandidate else { return nil }
        let mask = maskCandidate.mask

        let blendedImage: CIImage
        let blurRadius = 2.4 + Double(clampedStrength) * 0.9
        let blurredImage = inputImage
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
            .cropped(to: extent)
        blendedImage = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: inputImage,
                kCIInputBackgroundImageKey: blurredImage,
                kCIInputMaskImageKey: mask
            ]
        )?.outputImage?.cropped(to: extent) ?? inputImage

        let outputImage = applyPortraitEffect(to: blendedImage, effect: effect, strength: clampedStrength)
        guard let outputCGImage = ciContext.createCGImage(outputImage, from: extent),
              let data = UIImage(cgImage: outputCGImage, scale: normalizedImage.scale, orientation: .up).jpegData(compressionQuality: 0.92)
        else { return nil }
        return (data, maskCandidate.source)
    }

    private func scaledPortraitMask(_ mask: CIImage?, to extent: CGRect) -> CIImage? {
        guard let mask else { return nil }
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        let scaleX = extent.width / mask.extent.width
        let scaleY = extent.height / mask.extent.height
        return mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: extent)
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.9])
            .cropped(to: extent)
    }

    private func isUsablePortraitMask(_ mask: CIImage, extent: CGRect) -> Bool {
        let averageExtent = CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height)
        guard let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: mask.cropped(to: extent),
                kCIInputExtentKey: averageExtent
            ]
        )?.outputImage else {
            return true
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let coverage = Double(pixel[0]) / 255.0
        return coverage > 0.01 && coverage < 0.96
    }

    private func makePersonSegmentationMask(for image: CIImage, orientation: UIImage.Orientation) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, orientation: cgImagePropertyOrientation(for: orientation), options: [:])
        do {
            try handler.perform([request])
            guard let pixelBuffer = request.results?.first?.pixelBuffer else { return nil }
            let maskImage = CIImage(cvPixelBuffer: pixelBuffer)
            let scaleX = image.extent.width / maskImage.extent.width
            let scaleY = image.extent.height / maskImage.extent.height
            return maskImage
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: image.extent)
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 1.0])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8])
                .cropped(to: image.extent)
        } catch {
            return nil
        }
    }

    private func makeFacePortraitMask(for image: CIImage, orientation: UIImage.Orientation) -> CIImage? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: cgImagePropertyOrientation(for: orientation), options: [:])
        do {
            try handler.perform([request])
            guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
                return nil
            }
            let box = face.boundingBox
            let faceRect = CGRect(
                x: box.minX * image.extent.width,
                y: box.minY * image.extent.height,
                width: box.width * image.extent.width,
                height: box.height * image.extent.height
            )
            let centerX = faceRect.midX
            let centerY = min(image.extent.maxY, faceRect.midY - faceRect.height * 1.25)
            let radiusX = max(faceRect.width * 2.8, image.extent.width * 0.18)
            let radiusY = max(faceRect.height * 4.8, image.extent.height * 0.28)
            let radialMask = CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": CIVector(x: centerX, y: centerY),
                    "inputRadius0": min(radiusX, radiusY) * 0.65,
                    "inputRadius1": max(radiusX, radiusY),
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                ]
            )?.outputImage?.cropped(to: image.extent)
            return radialMask?
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.0])
                .cropped(to: image.extent)
        } catch {
            return nil
        }
    }

    private func makeSaliencyPortraitMask(for image: CIImage, orientation: UIImage.Orientation) -> CIImage? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: cgImagePropertyOrientation(for: orientation), options: [:])
        do {
            try handler.perform([request])
            guard let pixelBuffer = request.results?.first?.pixelBuffer else { return nil }
            let maskImage = CIImage(cvPixelBuffer: pixelBuffer)
            let scaledMask = scaledPortraitMask(maskImage, to: image.extent)
            return scaledMask?
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 2.2, "inputBrightness": -0.18])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.2])
                .cropped(to: image.extent)
        } catch {
            return nil
        }
    }

    private func cgImagePropertyOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private func applyPortraitEffect(to image: CIImage, effect: String, strength: Int) -> CIImage {
        switch effect {
        case "mono":
            return image.applyingFilter("CIPhotoEffectMono")
        case "low_key_mono":
            return image
                .applyingFilter("CIPhotoEffectNoir")
                .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -0.35])
                .applyingFilter("CIVignette", parameters: ["inputIntensity": 0.8, "inputRadius": max(image.extent.width, image.extent.height) * 0.58])
        case "high_key_mono":
            return image
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.4])
        case "studio":
            return image.applyingFilter(
                "CIColorControls",
                parameters: ["inputSaturation": 1.04, "inputContrast": 1.1, "inputBrightness": 0.03]
            )
        case "backdrop":
            return image.applyingFilter(
                "CIVignette",
                parameters: ["inputIntensity": 0.65 + Double(strength) * 0.06, "inputRadius": max(image.extent.width, image.extent.height) * 0.56]
            )
        case "color_point":
            return image.applyingFilter(
                "CIColorControls",
                parameters: ["inputSaturation": 1.28, "inputContrast": 1.08, "inputBrightness": 0.01]
            )
        default:
            return image.applyingFilter(
                "CIVignette",
                parameters: ["inputIntensity": 0.35 + Double(strength) * 0.04, "inputRadius": max(image.extent.width, image.extent.height) * 0.68]
            )
        }
    }
}
