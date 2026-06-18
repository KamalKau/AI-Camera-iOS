@preconcurrency import AVFoundation
import SwiftUI
import UIKit
#if canImport(WebRTC)
import WebRTC
#endif

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var lensFacing: LensFacing = .back

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.lensFacing = lensFacing
        view.updatePreviewConnection()
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        uiView.lensFacing = lensFacing
        uiView.updatePreviewConnection()
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var lensFacing: LensFacing = .back
    private var lastAppliedVideoOrientation: AVCaptureVideoOrientation?
    private var lastAppliedMirroring: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updatePreviewConnection()
    }

    func updatePreviewConnection() {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoOrientationSupported {
            let orientation = AVCaptureVideoOrientation.currentPreviewOrientation(lensFacing: lensFacing)
            if lastAppliedVideoOrientation != orientation {
                connection.videoOrientation = orientation
                lastAppliedVideoOrientation = orientation
            }
        }
        if connection.isVideoMirroringSupported {
            let isMirrored = lensFacing == .front
            if lastAppliedMirroring != isMirrored {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isMirrored
                lastAppliedMirroring = isMirrored
            }
        }
    }

    @objc private func deviceOrientationDidChange() {
        updatePreviewConnection()
    }
}

private extension AVCaptureVideoOrientation {
    static func currentPreviewOrientation(lensFacing: LensFacing) -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        default:
            return .portrait
        }
    }
}

struct CameraCircleButton: View {
    let systemName: String
    var size: CGFloat = 48
    var role: ButtonRole?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(isSelected ? Color.white : Color.black.opacity(0.42), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                .foregroundStyle(isSelected ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

struct CameraStatusPill: View {
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(primary)
                .font(.headline)
                .lineLimit(1)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }
}

struct CameraGridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for index in 1...2 {
                    let x = width * CGFloat(index) / 3.0
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                    let y = height * CGFloat(index) / 3.0
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(.white.opacity(0.38), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

struct FocusReticleView: View {
    let point: CGPoint

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 6)
                .stroke(.yellow, lineWidth: 2)
                .frame(width: 72, height: 72)
                .position(
                    x: point.x * geometry.size.width,
                    y: point.y * geometry.size.height
                )
        }
        .allowsHitTesting(false)
    }
}

struct FocusExposureOverlay: View {
    let point: CGPoint
    @Binding var exposureValue: Double
    var isInteractive = false
    var onExposureChanged: (Double) -> Void = { _ in }
    var onExposureCommitted: (Double) -> Void = { _ in }

    private let exposureTrackHeight: CGFloat = 142

    var body: some View {
        GeometryReader { geometry in
            let x = point.x * geometry.size.width
            let y = point.y * geometry.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.yellow, lineWidth: 2)
                    .frame(width: 72, height: 72)
                    .position(x: x, y: y)
                    .allowsHitTesting(false)

                exposureControl
                    .allowsHitTesting(isInteractive)
                    .position(
                        x: min(max(x + 58, 28), geometry.size.width - 28),
                        y: min(max(y, exposureTrackHeight / 2 + 26), geometry.size.height - exposureTrackHeight / 2 - 26)
                    )
            }
        }
    }

    private var exposureControl: some View {
        VStack(spacing: 7) {
            Image(systemName: "sun.max")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.yellow)

            Text(exposureLabel)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.34), in: Capsule())

            ZStack {
                Capsule()
                    .fill(.yellow.opacity(0.9))
                    .frame(width: 2, height: exposureTrackHeight)

                Circle()
                    .fill(.yellow)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 1)
                    .offset(y: knobOffset)

                Rectangle()
                    .fill(.clear)
                    .frame(width: 44, height: exposureTrackHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isInteractive else { return }
                                updateExposure(from: value.location.y, shouldCommit: false)
                            }
                            .onEnded { value in
                                guard isInteractive else { return }
                                updateExposure(from: value.location.y, shouldCommit: true)
                            }
                    )
            }
        }
        .frame(width: 48, height: exposureTrackHeight + 54)
    }

    private var exposureLabel: String {
        String(format: "%+.1f", exposureValue * 4.0)
    }

    private var knobOffset: CGFloat {
        -CGFloat(exposureValue) * exposureTrackHeight / 2
    }

    private func updateExposure(from yLocation: CGFloat, shouldCommit: Bool) {
        let clampedY = min(max(yLocation, 0), exposureTrackHeight)
        let normalized = 1.0 - Double(clampedY / exposureTrackHeight)
        let nextValue = min(max((normalized * 2.0) - 1.0, -1.0), 1.0)
        if abs(nextValue - exposureValue) > 0.01 {
            exposureValue = nextValue
            onExposureChanged(nextValue)
        }
        if shouldCommit {
            onExposureCommitted(nextValue)
        }
    }
}

extension String {
    var nextCameraAspectRatioMode: String {
        switch self {
        case "full": return "9_16"
        case "9_16": return "3_4"
        case "3_4": return "1_1"
        default: return "full"
        }
    }

    var cameraAspectRatioLabel: String {
        switch self {
        case "9_16": return "9:16"
        case "3_4": return "3:4"
        case "1_1": return "1:1"
        default: return "Full"
        }
    }

    var cameraAspectRatioValue: CGFloat? {
        switch self {
        case "9_16": return 9.0 / 16.0
        case "3_4": return 3.0 / 4.0
        case "1_1": return 1.0
        default: return nil
        }
    }

    var cameraPreviewAspectRatio: CGFloat {
        switch self {
        case "9_16": return 9.0 / 16.0
        case "3_4": return 3.0 / 4.0
        case "1_1": return 1.0
        default: return 9.0 / 16.0
        }
    }
}

#if canImport(WebRTC)
struct RemoteVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var isMirrored = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        UIView.performWithoutAnimation {
            uiView.transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
            uiView.layoutIfNeeded()
        }
        context.coordinator.update(track: track, renderer: uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.detach(renderer: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var currentTrack: RTCVideoTrack?

        func update(track: RTCVideoTrack?, renderer: RTCMTLVideoView) {
            guard currentTrack !== track else { return }
            detach(renderer: renderer)
            currentTrack = track
            track?.add(renderer)
        }

        func detach(renderer: RTCMTLVideoView) {
            currentTrack?.remove(renderer)
            currentTrack = nil
        }
    }
}
#endif
