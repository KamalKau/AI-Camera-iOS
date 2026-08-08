import SwiftUI
import UIKit

struct WaitingForApprovalScreen: View {
    let roomCode: String
    @Binding var path: NavigationPath

    @EnvironmentObject private var services: AppServices
    @State private var room: RoomDocument?
    @State private var lensFacing: LensFacing = .back
    @State private var zoomLevel = 1.0
    @State private var flashMode = "off"
    @State private var cameraMode = "photo"
    @State private var aspectRatioMode = RoomSchema.defaultAspectRatioMode
    @State private var pendingAspectRatioMode: String?
    @State private var isVideoRecording = false
    @State private var isVideoPaused = false
    @State private var videoRecordingStartedAt: Date?
    @State private var videoRecordingPausedAt: Date?
    @State private var accumulatedVideoPauseDuration: TimeInterval = 0
    @State private var errorMessage: String?
    @State private var zoomPublishTask: Task<Void, Never>?
    @State private var focusReticlePoint: CGPoint?
    @State private var exposureValue = 0.0
    @State private var exposurePublishTask: Task<Void, Never>?
    @State private var firstFrameRetryTask: Task<Void, Never>?
    @State private var firstFrameRetryCount = 0
    @State private var didPrewarmControllerStream = false
    @State private var isCaptureRequesting = false
    @State private var isSwitchingCameraDuringRecording = false
    @State private var captureFeedback: String?
    @State private var shutterFlashVisible = false
    @State private var isBoomerangArmed = false
    @State private var isBoomerangCaptureAnimating = false
    @State private var boomerangCaptureProgress = 0.0
    @State private var boomerangProgressTask: Task<Void, Never>?
    @State private var suppressPreviewNetworkWarningUntil = Date.distantPast
    @State private var burstCount = 0
    @State private var burstResetTask: Task<Void, Never>?
    @State private var isBurstCapturing = false
    @State private var burstCaptureTask: Task<Void, Never>?
    @State private var didTriggerBurstDrag = false
    @State private var suppressNextShutterTap = false
    @State private var controllerPreviewLensFacing: LensFacing = .back
    @State private var controllerPreviewLensTask: Task<Void, Never>?
    @State private var controllerPreviewLensTarget: LensFacing?
    @State private var controllerPreviewSwitching = false
    @State private var controllerLensSwitchTask: Task<Void, Never>?
    @State private var controllerPreviewSwitchStartFrameCount = 0
    @State private var showZoomBar = false
    @State private var showManualExposure = false
    @State private var showPortraitControls = false
    @State private var ignoreFocusTapUntil = Date.distantPast
    @State private var isControllerToolRailExpanded = false
    @State private var zoomGestureBaseLevel: Double?
    @State private var zoomWheelDragStartLevel: Double?
    @State private var lastZoomHapticMark: Double?
    @State private var lastLiveZoomPublishDate = Date.distantPast
    @State private var pendingLiveZoomLevel: Double?
    @State private var isLiveZoomPublishInFlight = false
    @State private var ignoreRoomZoomUntil = Date.distantPast

    var body: some View {
        ZStack {
            previewSurface
                .ignoresSafeArea()
                .simultaneousGesture(controllerZoomGesture)

            VStack {
                controllerTopBar
                if room?.controllerApproved == true {
                    Spacer()
                    controllerControls
                } else {
                    Spacer(minLength: 0)
                    approvalStatus
                    Spacer(minLength: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if room?.controllerApproved == true {
                if showZoomBar {
                    controllerZoomWheelOverlay
                        .transition(.scale(scale: 0.90, anchor: .bottom).combined(with: .opacity))
                }

                HStack {
                    Spacer(minLength: 0)
                    controllerToolRail
                }
                .frame(maxWidth: .infinity)
                .padding(.trailing, 10)
                .padding(.leading, 10)
            }

            if shutterFlashVisible {
                Color.white.opacity(0.32)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await observeRoom() }
        .onDisappear {
            zoomPublishTask?.cancel()
            exposurePublishTask?.cancel()
            firstFrameRetryTask?.cancel()
            controllerPreviewLensTask?.cancel()
            controllerLensSwitchTask?.cancel()
            boomerangProgressTask?.cancel()
            burstCaptureTask?.cancel()
            burstResetTask?.cancel()
            resetControllerSessionState()
            services.webRtcSession.stop()
        }
    }

    private var previewSurface: some View {
        GeometryReader { geometry in
            let layout = ControllerPreviewLayout(
                containerSize: geometry.size,
                aspectRatioMode: aspectRatioMode,
                sourceWidth: room?.previewWidth ?? 0,
                sourceHeight: room?.previewHeight ?? 0
            )

            ZStack(alignment: .topLeading) {
                Color.black

                controllerPreviewContent(layout: layout)
                    .frame(width: layout.visibleRect.width, height: layout.visibleRect.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(previewFocusGesture(layout: layout))
                    .position(x: layout.visibleRect.midX, y: layout.visibleRect.midY)
                    .id(aspectRatioMode)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func previewFocusGesture(layout: ControllerPreviewLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard room?.controllerApproved == true, Date.now >= ignoreFocusTapUntil else { return }
                guard abs(value.translation.width) < 8, abs(value.translation.height) < 8 else { return }
                let localPoint = value.location
                guard layout.videoDrawRectInVisibleRect.contains(localPoint) else { return }
                let sourcePoint = layout.sourcePoint(for: localPoint)
                sendFocusRequest(
                    sourcePoint: sourcePoint,
                    displayPoint: sourcePoint
                )
            }
    }

    private var controllerZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard room?.controllerApproved == true else { return }
                let baseLevel = zoomGestureBaseLevel ?? zoomLevel
                zoomGestureBaseLevel = baseLevel
                let nextLevel = clampedZoom(baseLevel * Double(scale))
                guard abs(nextLevel - zoomLevel) >= 0.02 else { return }
                zoomLevel = nextLevel
                ignoreRoomZoomUntil = Date.now.addingTimeInterval(0.8)
                publishZoomDebounced()
            }
            .onEnded { _ in
                zoomGestureBaseLevel = nil
                ignoreRoomZoomUntil = Date.now.addingTimeInterval(1.0)
                publishControls()
            }
    }

    private func updateFocusTapSuppression(isInteracting: Bool) {
        ignoreFocusTapUntil = Date.now.addingTimeInterval(isInteracting ? 0.35 : 0.12)
    }

    @ViewBuilder
    private func controllerPreviewContent(layout: ControllerPreviewLayout) -> some View {
        ZStack {
            #if canImport(WebRTC)
            if let remoteVideoTrack = services.webRtcSession.remoteVideoTrack {
                RemoteVideoView(track: remoteVideoTrack, isMirrored: controllerPreviewLensFacing == .front)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            } else {
                previewStatusOverlay
            }
            #else
            previewStatusOverlay
            #endif

            if room?.gridEnabled == true {
                ControllerVideoRectOverlay(videoDrawRect: layout.videoDrawRectInVisibleRect) {
                    CameraGridOverlay()
                }
            }

            if let room, cameraMode == "portrait" {
                ControllerPortraitSubjectOverlay(
                    state: room.portraitSubjectState,
                    faceDetectionState: room.faceDetectionOverlayState,
                    videoDrawRect: layout.videoDrawRectInVisibleRect,
                    isMirrored: false
                )
            }

            if let room {
                ControllerFaceOverlay(
                    state: room.faceDetectionOverlayState,
                    videoDrawRect: layout.videoDrawRectInVisibleRect,
                    isMirrored: false
                )
            }

            if let focusReticlePoint {
                ControllerVideoRectOverlay(videoDrawRect: layout.videoDrawRectInVisibleRect) {
                    FocusExposureOverlay(
                        point: focusReticlePoint,
                        exposureValue: $exposureValue,
                        isInteractive: true,
                        onExposureChanged: publishExposureDebounced,
                        onExposureCommitted: publishExposureDebounced,
                        onInteractionChanged: updateFocusTapSuppression
                    )
                }
            }

            if let message = previewConnectionOverlayText {
                ControllerVideoRectOverlay(videoDrawRect: layout.videoDrawRectInVisibleRect) {
                    ControllerPreviewConnectionOverlay(message: message)
                }
            }

            if controllerPreviewSwitching {
                CameraSwitchingOverlay()
            }
        }
    }

    private var previewStatusOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: room?.controllerApproved == true ? "video" : "hourglass")
                .font(.system(size: 36))
            Text(previewStatusText)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding()
    }

    private var controllerTopBar: some View {
        VStack(spacing: 10) {
            ZStack {
                ControllerTopStatusPill(text: statusText)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    Spacer(minLength: 0)
                    ControllerEndButton {
                        endSession()
                    }
                }
            }

            ControllerRoomCodeCard(roomCode: roomCode)
                .frame(maxWidth: 230)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var approvalStatus: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.56, green: 0.33, blue: 1.0), Color(red: 0.22, green: 0.50, blue: 1.0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color(red: 0.48, green: 0.28, blue: 1.0).opacity(0.45), radius: 18, y: 8)

                Image(systemName: room?.status == .denied ? "xmark" : "paperplane.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text(room?.status == .denied ? "Request Denied" : "Request Sent")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text(room?.status == .denied ? "The camera phone denied this connection." : "Waiting for the camera phone to approve control access.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            HStack(spacing: 8) {
                Text("ROOM")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.54))
                Text(roomCode.map(String.init).joined(separator: " "))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))

            if room?.status == .denied {
                Button {
                    returnToStart()
                } label: {
                    Text("Enter Another Code")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.70, green: 0.42, blue: 1.0), Color(red: 0.34, green: 0.08, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .tint(.white)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.48))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 360)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.07, blue: 0.21).opacity(0.95),
                    Color.black.opacity(0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color(red: 0.55, green: 0.34, blue: 1.0).opacity(0.50), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 30, y: 14)
    }

    private var previewConnectionOverlayText: String? {
        guard room?.controllerApproved == true else { return nil }
        guard Date.now >= suppressPreviewNetworkWarningUntil else { return nil }
        if firstFrameRetryCount > 0 {
            return "Reconnecting preview"
        }
        switch services.webRtcSession.state {
        case .connecting, .waitingForVideo:
            return services.webRtcSession.remoteVideoTrack == nil ? nil : "Weak network"
        case .failed:
            return "Connection lost"
        default:
            return nil
        }
    }

    private var previewStatusText: String {
        if room?.status == .ended { return "Session ended" }
        guard room?.controllerApproved == true else { return "Waiting for host approval" }
        if firstFrameRetryCount > 0, services.webRtcSession.remoteVideoTrack == nil {
            return "Reconnecting live preview"
        }
        switch services.webRtcSession.state {
        case .unavailable:
            return "WebRTC package is not linked to this app target"
        case .connecting:
            return "Connecting to camera"
        case .waitingForVideo:
            return "Waiting for camera video"
        case .connected:
            return "Waiting for remote video track"
        case .failed:
            return "Live preview connection failed"
        case .idle:
            return "Preparing live preview"
        }
    }

    private var controllerControls: some View {
        VStack(spacing: 12) {
            controllerAccessoryPanel
            controllerPrimaryControls
            controllerStatusOverlays
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var controllerAccessoryPanel: some View {
        if showManualExposure {
            manualExposurePanel
        } else if showPortraitControls && cameraMode == "portrait" {
            portraitControlsPanel
        } else {
            bottomZoomControls
        }
    }

    private var bottomZoomControls: some View {
        VStack(spacing: 8) {
            if !showZoomBar {
                zoomPresetStrip
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: showZoomBar)
    }

    private var controllerZoomWheelOverlay: some View {
        GeometryReader { geometry in
            let wheelWidth = min(geometry.size.width, 390)
            let wheelHeight: CGFloat = 142
            let bottomOffset = min(max(geometry.size.height * 0.24, 170), 230)

            VStack {
                Spacer()
                bottomCurvedZoomWheel
                    .frame(width: wheelWidth, height: wheelHeight)
                    .offset(y: 24)
                    .padding(.bottom, bottomOffset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(curvedZoomWheelGesture(travel: 340))
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: showZoomBar)
    }

    private var controllerModeStrip: some View {
        HStack(spacing: 6) {
            modeButton("photo", label: "PHOTO")
            modeButton("video", label: "VIDEO")
            modeButton("portrait", label: "PORTRAIT")
        }
        .padding(4)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var controllerPrimaryControls: some View {
        VStack(spacing: 10) {
            burstCountPill
            shutterButton

            ZStack {
                controllerModeStrip
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    if cameraMode == "video" {
                        videoHdrButton
                    }
                    Spacer(minLength: 0)
                    lensFlipButton(size: 54)
                }
            }
            .frame(maxWidth: 340)

            if isVideoRecording {
                recordingControls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var controllerStatusOverlays: some View {
        if isVideoRecording {
            recordingStatusPill
        }

        if let captureFeedback {
            Text(captureFeedback)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.48), in: Capsule())
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private var zoomPresetStrip: some View {
        HStack(spacing: 12) {
            ForEach(zoomChipOptions, id: \.self) { option in
                let isSelected = abs(zoomLevel - option) < 0.08
                Button {
                    if !isSelected {
                        zoomLevel = clampedZoom(option)
                        ignoreRoomZoomUntil = Date.now.addingTimeInterval(1.0)
                        publishZoomImmediately()
                    }
                } label: {
                    Text(zoomChipLabel(for: option, isSelected: isSelected))
                        .font(.system(size: isSelected ? 18 : 17, weight: isSelected ? .black : .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.yellow : .white.opacity(0.92))
                        .frame(width: 54, height: 54)
                        .background {
                            if isSelected {
                                Circle()
                                    .fill(Color.black.opacity(0.58))
                                    .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.16).onEnded { _ in
                    if !isSelected {
                        zoomLevel = clampedZoom(option)
                        ignoreRoomZoomUntil = Date.now.addingTimeInterval(1.0)
                        publishZoomImmediately()
                    }
                    openZoomWheel()
                })
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var commonZoomOptions: [Double] {
        let options = [0.5, 1.0, 2.0, 3.0]
        return options.filter { $0 >= minimumZoom && $0 <= maximumZoom }
    }

    private var zoomChipOptions: [Double] {
        let roundedCurrentZoom = (zoomLevel * 10).rounded() / 10
        var options = commonZoomOptions
        if !options.contains(where: { abs($0 - roundedCurrentZoom) < 0.08 }) {
            options.append(clampedZoom(roundedCurrentZoom))
        }
        return Array(Set(options.map { ($0 * 10).rounded() / 10 })).sorted()
    }

    private func zoomChipLabel(for option: Double, isSelected: Bool) -> String {
        if isSelected {
            if option.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fx", option)
            }
            return String(format: "%.1fx", option)
        }
        if option.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", option)
        }
        return String(format: "%.1f", option)
    }

    private var minimumZoom: Double {
        max(0.5, room?.minZoom ?? 0.5)
    }

    private var maximumZoom: Double {
        max(minimumZoom, room?.maxZoom ?? 8.0)
    }

    private func clampedZoom(_ value: Double) -> Double {
        min(maximumZoom, max(minimumZoom, value))
    }

    private var manualExposurePanel: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showManualExposure = false }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(exposureLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    exposureValue = 0
                    publishExposureDebounced(0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            Slider(value: $exposureValue, in: -1.0...1.0, step: 0.125)
                .tint(.yellow)
                .onChange(of: exposureValue) { _, value in publishExposureDebounced(value) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private var exposureLabel: String {
        String(format: "EV %+.1f", exposureValue * 4.0)
    }

    private var portraitControlsPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(1...7), id: \.self) { strength in
                    let isSelected = (room?.portraitStrength ?? 5) == strength
                    Button {
                        updatePortraitControls(strength: strength, effect: room?.portraitEffect ?? "blur")
                    } label: {
                        Text("\(strength)")
                            .font(.caption.weight(.semibold))
                            .frame(width: 38, height: 32)
                            .background(isSelected ? Color.white : Color.black.opacity(0.4), in: Capsule())
                            .foregroundStyle(isSelected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["blur", "studio", "mono", "backdrop", "low_key_mono", "high_key_mono", "color_point"], id: \.self) { effect in
                        let isSelected = (room?.portraitEffect ?? "blur") == effect
                        Button {
                            updatePortraitControls(strength: room?.portraitStrength ?? 5, effect: effect)
                        } label: {
                            Text(portraitEffectLabel(effect))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(isSelected ? Color.white : Color.black.opacity(0.4), in: Capsule())
                                .foregroundStyle(isSelected ? .black : .white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private func portraitEffectLabel(_ effect: String) -> String {
        switch effect {
        case "low_key_mono": return "Low Key"
        case "high_key_mono": return "High Key"
        case "color_point": return "Color"
        default: return effect.capitalized
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 14) {
            AndroidControlButton(
                systemName: isVideoPaused ? "play.fill" : "pause.fill",
                label: isVideoPaused ? "Resume" : "Pause",
                isSelected: isVideoPaused
            ) {
                requestVideoPauseResume()
            }
            .disabled(isCaptureRequesting || isSwitchingCameraDuringRecording)

            AndroidControlButton(systemName: "stop.fill", label: "Stop", tint: .red) {
                requestCapture()
            }
            .disabled(isCaptureRequesting)
        }
    }

    private var lensFlipButton: some View {
        lensFlipButton(size: 58)
    }

    private func lensFlipButton(size: CGFloat) -> some View {
        AndroidControlButton(
            systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill",
            label: "Flip",
            size: size
        ) {
            switchControllerLens()
        }
        .disabled(isSwitchingCameraDuringRecording)
    }

    private var captureModeBadge: some View {
        Text(cameraModeDisplayLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(cameraMode == "video" ? .red : .yellow)
            .frame(height: 14)
    }

    private var cameraModeDisplayLabel: String {
        switch cameraMode {
        case "video": return isVideoRecording ? "REC" : "VIDEO"
        case "portrait": return "PORTRAIT"
        default: return "PHOTO"
        }
    }

    @ViewBuilder
    private var burstCountPill: some View {
        if burstCount > 1 {
            Text("BURST \(burstCount)")
                .font(.system(size: 11, weight: .black).monospacedDigit())
                .foregroundStyle(.yellow)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.58), in: Capsule())
                .overlay(Capsule().stroke(.yellow.opacity(0.42), lineWidth: 1))
        }
    }

    private var recordingStatusPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 7) {
                Circle()
                    .fill(isVideoPaused ? .yellow : .red)
                    .frame(width: 7, height: 7)
                Text("\(isVideoPaused ? "PAUSED" : "REC") \(formattedRecordingDuration(at: timeline.date))")
                    .font(.caption2.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.48), in: Capsule())
            .overlay(Capsule().stroke((isVideoPaused ? Color.yellow : Color.red).opacity(0.42), lineWidth: 1))
        }
    }

    private func formattedRecordingDuration(at date: Date) -> String {
        let elapsed = max(0, Int(recordingDuration(at: date).rounded(.down)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func recordingDuration(at date: Date) -> TimeInterval {
        guard let videoRecordingStartedAt else { return 0 }
        let referenceDate = videoRecordingPausedAt ?? date
        return max(0, referenceDate.timeIntervalSince(videoRecordingStartedAt) - accumulatedVideoPauseDuration)
    }

    private var portraitToggleButton: some View {
        AndroidControlButton(
            systemName: "person.crop.rectangle",
            label: "Portrait",
            isSelected: cameraMode == "portrait"
        ) {
            if cameraMode != "portrait" {
                updateCameraMode("portrait")
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                showManualExposure = false
                showZoomBar = false
                showPortraitControls.toggle()
            }
        }
    }

    private var videoHdrButton: some View {
        AndroidControlButton(
            systemName: "h.square",
            label: "HDR",
            isSelected: room?.videoHdrEnabled == true
        ) {
            updateVideoHdrEnabled(!(room?.videoHdrEnabled ?? false))
        }
    }

    private func modeButton(_ mode: String, label: String) -> some View {
        Button { updateCameraMode(mode) } label: {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0)
                .foregroundStyle(cameraMode == mode ? .black : .white.opacity(0.62))
                .frame(minWidth: 64, minHeight: 30)
                .background(cameraMode == mode ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var controllerToolRail: some View {
        VStack(spacing: 12) {
            ControllerRailButton(
                systemName: flashMode.cameraFlashIconName,
                label: flashMode.cameraFlashLabel,
                isSelected: flashMode != "off"
            ) {
                flashMode = flashMode.nextCameraFlashMode
                publishControls()
            }

            ControllerRailButton(systemName: "square.grid.3x3", label: "Grid", isSelected: room?.gridEnabled == true) {
                updateGridEnabled(!(room?.gridEnabled ?? false))
            }

            ControllerRailButton(systemName: "aspectratio", label: aspectRatioMode.cameraAspectRatioLabel) {
                updateAspectRatioMode(aspectRatioMode.nextCameraAspectRatioMode)
            }

            if isControllerToolRailExpanded {
                ControllerRailButton(
                    systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill",
                    label: "Lens"
                ) {
                    switchControllerLens()
                }
                .disabled(isSwitchingCameraDuringRecording || isCaptureRequesting)

                ControllerRailButton(systemName: "plus.magnifyingglass", label: "Zoom", isSelected: showZoomBar) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showManualExposure = false
                        showPortraitControls = false
                        showZoomBar.toggle()
                    }
                }

                ControllerRailButton(systemName: "sun.max", label: "EV", isSelected: showManualExposure) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showZoomBar = false
                        showPortraitControls = false
                        showManualExposure.toggle()
                    }
                }

                ControllerRailButton(systemName: "sparkles", label: "Scene", isSelected: room?.sceneDetectionEnabled == true) {
                    updateSceneDetectionEnabled(!(room?.sceneDetectionEnabled ?? false))
                }

                ControllerRailButton(systemName: "moon.stars", label: "Night", isSelected: room?.nightModeEnabled == true) {
                    updateNightModeEnabled(!(room?.nightModeEnabled ?? false))
                }

                ControllerRailButton(systemName: "h.square", label: "HDR", isSelected: room?.videoHdrEnabled == true) {
                    updateVideoHdrEnabled(!(room?.videoHdrEnabled ?? false))
                }

                if !isVideoRecording {
                    ControllerRailButton(systemName: "infinity", label: "Boom", isSelected: isBoomerangArmed) {
                        armBoomerangShutter()
                    }
                    .disabled(isCaptureRequesting || isSwitchingCameraDuringRecording)
                }

            }

            ControllerRailButton(systemName: isControllerToolRailExpanded ? "chevron.up" : "ellipsis", label: isControllerToolRailExpanded ? "Less" : "More") {
                updateControllerToolRailExpanded(!isControllerToolRailExpanded)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.46), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .animation(.easeInOut(duration: 0.18), value: isControllerToolRailExpanded)
    }

    private var zoomStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.10), in: Circle())

                zoomWheel

                Text(String(format: "%.1fx", zoomLevel))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .frame(width: 48, alignment: .trailing)
            }

            zoomPresetStrip
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 330)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var bottomCurvedZoomWheel: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height + 86)
            let radius = min(size.width * 0.62, size.height * 1.62)
            let tickCount = 101
            let selectedFraction = zoomWheelFraction(for: zoomLevel)
            let startDegrees = 210.0
            let sweepDegrees = 120.0
            let centerDegrees = 270.0
            let scaleOffset = centerDegrees - (startDegrees + sweepDegrees * selectedFraction)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.76), Color.black.opacity(0.34)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: (radius + 22) * 2, height: (radius + 22) * 2)
                    .position(center)

                ForEach(0..<tickCount, id: \.self) { index in
                    let fraction = Double(index) / Double(tickCount - 1)
                    let angle = Angle.degrees(startDegrees + (sweepDegrees * fraction) + scaleOffset)
                    let distanceFromCenter = abs(angle.degrees - centerDegrees)
                    let isMajorTick = index % 16 == 0
                    let isCenterTick = distanceFromCenter < 1.2
                    let tickLength: CGFloat = isCenterTick ? 0 : (isMajorTick ? 16 : 7)

                    Capsule()
                        .fill(Color.white.opacity(isMajorTick ? 0.68 : 0.34))
                        .frame(width: 0.75, height: tickLength)
                        .rotationEffect(angle + .degrees(90))
                        .position(arcPoint(center: center, radius: radius, angle: angle))
                }

                ForEach(zoomWheelLabels, id: \.value) { mark in
                    let angle = Angle.degrees(startDegrees + (sweepDegrees * mark.fraction) + scaleOffset)
                    VStack(spacing: 2) {
                        Text(mark.label)
                            .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                        if mark.value < zoomLevel - 0.08 || mark.value > zoomLevel + 0.08 {
                            Text(focalLengthLabel(for: mark.value))
                                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        }
                    }
                    .foregroundStyle(mark.isSelected ? Color.yellow : Color.white.opacity(mark.isSelected ? 1.0 : 0.86))
                    .rotationEffect(angle - .degrees(270))
                    .position(arcPoint(center: center, radius: radius - 40, angle: angle))
                }

                VStack(spacing: 5) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(180))
                        .foregroundStyle(.yellow)
                    Capsule()
                        .fill(Color.yellow)
                        .frame(width: 3, height: 20)
                    Text(zoomValueLabel(for: zoomLevel))
                        .font(.system(size: 18, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(.yellow)
                    Text(focalLengthLabel(for: zoomLevel).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.yellow.opacity(0.92))
                }
                .position(x: size.width / 2, y: 58)
            }
            .contentShape(Rectangle())
            .gesture(curvedZoomWheelGesture(travel: 340))
        }
        .accessibilityLabel("Zoom wheel")
        .accessibilityValue(String(format: "%.1fx", zoomLevel))
    }

    private var zoomWheel: some View {
        GeometryReader { geometry in
            let tickCount = 39
            let centerIndex = tickCount / 2

            ZStack {
                HStack(spacing: 5) {
                    ForEach(0..<tickCount, id: \.self) { index in
                        let distance = abs(index - centerIndex)
                        Capsule()
                            .fill(distance == 0 ? Color.yellow : Color.white.opacity(distance % 5 == 0 ? 0.70 : 0.36))
                            .frame(width: distance == 0 ? 3 : 2, height: zoomTickHeight(distance: distance))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 2) {
                    Text(String(format: "%.1f", zoomLevel))
                        .font(.system(size: 13, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(.yellow)
                    Text("x")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.yellow.opacity(0.86))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().stroke(Color.yellow.opacity(0.28), lineWidth: 1))
            }
            .contentShape(Rectangle())
            .gesture(zoomWheelGesture(width: geometry.size.width))
        }
        .frame(height: 44)
        .accessibilityLabel("Zoom wheel")
    }

    private func zoomTickHeight(distance: Int) -> CGFloat {
        if distance == 0 {
            return 34
        }
        if distance % 5 == 0 {
            return 24
        }
        return 14
    }

    private var zoomFraction: Double {
        let range = maximumZoom - minimumZoom
        guard range > 0 else { return 0 }
        return 1 - ((clampedZoom(zoomLevel) - minimumZoom) / range)
    }

    private var zoomWheelLabels: [(value: Double, label: String, fraction: Double, isSelected: Bool)] {
        zoomWheelDisplayOptions.map { value in
            let fraction = zoomWheelFraction(for: value)
            let label = zoomWheelMarkLabel(for: value)
            return (value, label, fraction, abs(zoomLevel - value) < 0.08)
        }
    }

    private var zoomWheelDisplayOptions: [Double] {
        var options = [0.5, 1.0, 2.0, 3.0].filter { $0 >= minimumZoom && $0 <= maximumZoom }
        if maximumZoom > 3.5 {
            options.append(maximumZoom)
        } else if options.isEmpty {
            options = [minimumZoom, maximumZoom].filter { $0 >= minimumZoom && $0 <= maximumZoom }
        }
        return Array(Set(options.map { ($0 * 10).rounded() / 10 })).sorted()
    }

    private var zoomWheelMinimumDisplayZoom: Double {
        minimumZoom
    }

    private var zoomWheelMaximumDisplayZoom: Double {
        maximumZoom
    }

    private func zoomWheelFraction(for value: Double) -> Double {
        let lower = max(0.1, zoomWheelMinimumDisplayZoom)
        let upper = max(lower, zoomWheelMaximumDisplayZoom)
        guard upper > lower else { return 0.5 }
        let clampedValue = min(upper, max(lower, value))
        return log(clampedValue / lower) / log(upper / lower)
    }

    private func zoomLevel(forWheelFraction fraction: Double) -> Double {
        let lower = max(0.1, zoomWheelMinimumDisplayZoom)
        let upper = max(lower, zoomWheelMaximumDisplayZoom)
        guard upper > lower else { return lower }
        let clampedFraction = min(1.0, max(0.0, fraction))
        return clampedZoom(lower * pow(upper / lower, clampedFraction))
    }

    private func focalLengthLabel(for zoom: Double) -> String {
        "\(Int((26 * zoom).rounded()))MM"
    }

    private func zoomWheelMarkLabel(for value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func zoomValueLabel(for value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0fx", value)
        }
        return String(format: "%.1fx", value)
    }

    private func arcPoint(center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        let radians = CGFloat(angle.radians)
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }

    private func openZoomWheel() {
        zoomWheelDragStartLevel = zoomLevel
        lastZoomHapticMark = nearestZoomHapticMark(to: zoomLevel)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            showManualExposure = false
            showPortraitControls = false
            showZoomBar = true
        }
    }

    private func closeZoomWheel() {
        zoomWheelDragStartLevel = nil
        zoomLevel = (zoomLevel * 10).rounded() / 10
        ignoreRoomZoomUntil = Date.now.addingTimeInterval(1.0)
        zoomPublishTask?.cancel()
        zoomPublishTask = nil
        pendingLiveZoomLevel = zoomLevel
        if !isLiveZoomPublishInFlight {
            startLiveZoomPublish()
        }
        withAnimation(.easeOut(duration: 0.20)) {
            showZoomBar = false
        }
    }

    private func updateZoomFromWheelDrag(_ verticalTranslation: CGFloat, travel: CGFloat) {
        let startLevel = zoomWheelDragStartLevel ?? zoomLevel
        zoomWheelDragStartLevel = startLevel
        let normalizedDelta = -Double(verticalTranslation / max(travel, 1))
        let startFraction = zoomWheelFraction(for: startLevel)
        let nextFraction = min(1.0, max(0.0, startFraction + normalizedDelta * 0.58))
        let nextLevel = zoomLevel(forWheelFraction: nextFraction)
        guard abs(nextLevel - zoomLevel) >= 0.002 else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            zoomLevel = nextLevel
        }
        ignoreRoomZoomUntil = Date.now.addingTimeInterval(0.8)
        triggerZoomHapticIfNeeded(for: nextLevel)
        publishZoomDebounced()
    }

    private func nearestZoomHapticMark(to value: Double) -> Double? {
        zoomWheelDisplayOptions.min { abs($0 - value) < abs($1 - value) }
    }

    private func triggerZoomHapticIfNeeded(for value: Double) {
        guard let mark = nearestZoomHapticMark(to: value), abs(mark - value) < 0.025 else { return }
        guard lastZoomHapticMark != mark else { return }
        lastZoomHapticMark = mark
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func zoomWheelGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startLevel = zoomWheelDragStartLevel ?? zoomLevel
                zoomWheelDragStartLevel = startLevel
                let normalizedDelta = -Double(value.translation.width / max(width, 1))
                let zoomRange = max(maximumZoom - minimumZoom, 1)
                let nextLevel = clampedZoom(startLevel + normalizedDelta * zoomRange)
                guard abs(nextLevel - zoomLevel) >= 0.02 else { return }
                zoomLevel = nextLevel
                publishZoomDebounced()
            }
            .onEnded { _ in
                zoomWheelDragStartLevel = nil
                zoomLevel = (zoomLevel * 10).rounded() / 10
                publishControls()
            }
    }

    private func curvedZoomWheelGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateZoomFromWheelDrag(value.translation.height, travel: travel)
            }
            .onEnded { _ in
                closeZoomWheel()
            }
    }

    private var shutterButton: some View {
        Button { requestCapture() } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(shutterRingColor, lineWidth: 5)
                        .frame(width: 86, height: 86)

                    if isBoomerangCaptureAnimating {
                        Circle()
                            .trim(from: 0, to: boomerangCaptureProgress)
                            .stroke(.yellow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 86, height: 86)
                            .rotationEffect(.degrees(-90))
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 12, height: 12)
                    } else if cameraMode == "video", isVideoRecording {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.red)
                            .frame(width: 38, height: 38)
                    } else if isBoomerangArmed {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: shutterInnerSize, height: shutterInnerSize)
                        Image(systemName: "infinity")
                            .font(.system(size: 25, weight: .black))
                            .foregroundStyle(.black)
                    } else if cameraMode == "video" {
                        Circle()
                            .fill(Color.red)
                            .frame(width: shutterInnerSize, height: shutterInnerSize)
                    } else {
                        Circle()
                            .fill(shutterFillColor)
                            .frame(width: shutterInnerSize, height: shutterInnerSize)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isCaptureRequesting)
                .animation(.easeOut(duration: 0.16), value: isVideoRecording)
                .animation(.easeOut(duration: 0.16), value: cameraMode)
                .animation(.easeOut(duration: 0.16), value: isBoomerangArmed)
                .animation(.linear(duration: 0.08), value: boomerangCaptureProgress)

                Text(shutterStateLabel)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(shutterRingColor)
                    .frame(height: 13)
            }
        }
        .buttonStyle(.plain)
        .disabled(isCaptureRequesting || isSwitchingCameraDuringRecording || room?.status == .ended)
        .simultaneousGesture(shutterBurstDragGesture)
        .accessibilityLabel(shutterStateLabel)
    }

    private var shutterBurstDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !didTriggerBurstDrag else { return }
                guard cameraMode == "photo" || cameraMode == "portrait" else { return }
                guard value.translation.width <= -34, abs(value.translation.height) <= 42 else { return }
                guard startBurstCaptureIfPossible() else { return }
                didTriggerBurstDrag = true
                suppressNextShutterTap = true
            }
            .onEnded { _ in
                didTriggerBurstDrag = false
                stopBurstCapture()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    suppressNextShutterTap = false
                }
            }
    }

    private var shutterInnerSize: CGFloat {
        isCaptureRequesting ? 58 : 64
    }

    private var shutterFillColor: Color {
        isCaptureRequesting ? .white.opacity(0.72) : .white
    }

    private var shutterRingColor: Color {
        if isBoomerangCaptureAnimating { return .yellow }
        if cameraMode == "video" || isVideoRecording { return .red }
        if isBoomerangArmed { return .yellow }
        if cameraMode == "portrait" { return Color(red: 0.78, green: 0.62, blue: 1.0) }
        return .white.opacity(0.96)
    }

    private var shutterStateLabel: String {
        if isBoomerangCaptureAnimating { return "BOOM" }
        if isBoomerangArmed { return "BOOM \(BoomerangCaptureDefaults.durationLabel)" }
        if cameraMode == "video" { return isVideoRecording ? "STOP" : "VIDEO" }
        if cameraMode == "portrait" { return "PORTRAIT" }
        return "PHOTO"
    }

    private var statusText: String {
        guard let room else { return "Connecting to room" }
        switch room.status {
        case .created, .waitingForApproval: return "Host approval required"
        case .connected:
            if firstFrameRetryCount > 0, services.webRtcSession.remoteVideoTrack == nil {
                return "Reconnecting preview \(firstFrameRetryCount)/3"
            }
            return services.webRtcSession.state == .connected ? "Connected" : "Starting preview"
        case .denied: return "Request denied"
        case .disconnected: return "Disconnected"
        case .ended: return "Session ended"
        }
    }

    private func observeRoom() async {
        do {
            for try await nextRoom in await services.roomReader.observeRoom(roomCode: roomCode) {
                room = nextRoom
                if nextRoom.status == .ended {
                    returnToStart()
                    return
                }
                if nextRoom.status == .denied {
                    resetControllerSessionState()
                    cancelFirstFrameRetry()
                    services.webRtcSession.stop()
                    continue
                }
                services.webRtcSession.applyStreamQualityMode(nextRoom.streamQualityMode)
                let shouldDelayPreviewLens = didPrewarmControllerStream && controllerPreviewLensFacing != nextRoom.lensFacing
                lensFacing = nextRoom.lensFacing
                if shouldDelayPreviewLens {
                    scheduleControllerPreviewLensFacing(nextRoom.lensFacing)
                } else {
                    controllerPreviewLensTask?.cancel()
                    controllerPreviewLensTarget = nil
                    controllerPreviewLensFacing = nextRoom.lensFacing
                    controllerPreviewSwitching = false
                }
                if !showZoomBar && zoomWheelDragStartLevel == nil && Date.now >= ignoreRoomZoomUntil {
                    zoomLevel = nextRoom.zoomLevel
                }
                flashMode = nextRoom.flashMode.safeCameraFlashMode
                cameraMode = nextRoom.cameraMode
                syncAspectRatioModeFromRoom(nextRoom.aspectRatioMode)
                syncControllerToolRailExpandedFromRoom(nextRoom.toolbarExpanded)
                exposureValue = Double(nextRoom.exposureIndex) / 8.0
                if !didPrewarmControllerStream {
                    didPrewarmControllerStream = true
                    await services.webRtcSession.startController(roomCode: roomCode, repository: services.roomSignalingRepository)
                }
                if !nextRoom.controllerApproved {
                    cancelFirstFrameRetry()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleControllerPreviewLensFacing(_ lensFacing: LensFacing) {
        guard controllerPreviewLensTarget != lensFacing else { return }
        controllerPreviewLensTarget = lensFacing
        controllerPreviewLensTask?.cancel()
        controllerPreviewSwitchStartFrameCount = services.webRtcSession.decodedVideoFrameCount
        controllerPreviewSwitching = true
        controllerPreviewLensTask = Task { @MainActor in
            await finishControllerPreviewSwitch(to: lensFacing, startFrameCount: controllerPreviewSwitchStartFrameCount)
        }
    }

    private func finishControllerPreviewSwitch(to lensFacing: LensFacing, startFrameCount: Int) async {
        let minimumDelayMilliseconds = 250
        let maximumDelayMilliseconds = 1200
        var elapsedMilliseconds = 0

        while elapsedMilliseconds < minimumDelayMilliseconds {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            elapsedMilliseconds += 100
        }

        while services.webRtcSession.decodedVideoFrameCount <= startFrameCount && elapsedMilliseconds < maximumDelayMilliseconds {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            elapsedMilliseconds += 100
        }

        controllerPreviewLensFacing = lensFacing
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        controllerPreviewSwitching = false
        controllerPreviewLensTarget = nil
    }

    private func cancelFirstFrameRetry() {
        firstFrameRetryTask?.cancel()
        firstFrameRetryTask = nil
        if services.webRtcSession.remoteVideoTrack != nil {
            firstFrameRetryCount = 0
        }
    }

    private func switchControllerLens() {
        guard !isSwitchingCameraDuringRecording else { return }
        let nextLensFacing: LensFacing = lensFacing == .back ? .front : .back
        isSwitchingCameraDuringRecording = true
        controllerPreviewSwitching = true
        controllerPreviewLensTarget = nextLensFacing
        controllerPreviewSwitchStartFrameCount = services.webRtcSession.decodedVideoFrameCount
        captureFeedback = "Switching camera"
        controllerLensSwitchTask?.cancel()
        controllerPreviewLensTask?.cancel()

        controllerLensSwitchTask = Task { @MainActor in
            lensFacing = nextLensFacing

            if cameraMode == "video" && isVideoRecording {
                do {
                    try await services.roomCameraControlUpdater.updateControls(
                        roomCode: roomCode,
                        lensFacing: nextLensFacing,
                        zoomLevel: zoomLevel,
                        flashMode: flashMode
                    )
                    await finishControllerPreviewSwitch(to: nextLensFacing, startFrameCount: controllerPreviewSwitchStartFrameCount)
                    if captureFeedback == "Switching camera" {
                        captureFeedback = nil
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    controllerPreviewSwitching = false
                    controllerPreviewLensTarget = nil
                }
                isSwitchingCameraDuringRecording = false
                return
            }

            publishControls()
            await finishControllerPreviewSwitch(to: nextLensFacing, startFrameCount: controllerPreviewSwitchStartFrameCount)
            if captureFeedback == "Switching camera" {
                captureFeedback = nil
            }
            isSwitchingCameraDuringRecording = false
        }
    }

    private func publishControls() {
        zoomPublishTask?.cancel()
        Task {
            do {
                try await services.roomCameraControlUpdater.updateControls(roomCode: roomCode, lensFacing: lensFacing, zoomLevel: zoomLevel, flashMode: flashMode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publishZoomDebounced() {
        if showZoomBar {
            publishZoomLiveThrottled()
            return
        }
        zoomPublishTask?.cancel()
        zoomPublishTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            do {
                try await services.roomCameraControlUpdater.updateZoomLevel(roomCode: roomCode, zoomLevel: zoomLevel)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func publishZoomImmediately() {
        zoomPublishTask?.cancel()
        zoomPublishTask = nil
        pendingLiveZoomLevel = zoomLevel
        if !isLiveZoomPublishInFlight {
            startLiveZoomPublish()
        }
    }

    private func publishZoomLiveThrottled() {
        let now = Date()
        let minimumInterval: TimeInterval = 0.075
        let elapsed = now.timeIntervalSince(lastLiveZoomPublishDate)
        pendingLiveZoomLevel = zoomLevel

        guard !isLiveZoomPublishInFlight else { return }

        if elapsed >= minimumInterval {
            startLiveZoomPublish()
            return
        }

        guard zoomPublishTask == nil else { return }
        let delay = max(0, minimumInterval - elapsed)
        zoomPublishTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                zoomPublishTask = nil
                startLiveZoomPublish()
            }
        }
    }

    private func startLiveZoomPublish() {
        guard !isLiveZoomPublishInFlight else { return }
        let levelToPublish = pendingLiveZoomLevel ?? zoomLevel
        pendingLiveZoomLevel = nil
        lastLiveZoomPublishDate = Date()
        isLiveZoomPublishInFlight = true

        Task {
            do {
                try await services.roomCameraControlUpdater.updateZoomLevel(roomCode: roomCode, zoomLevel: levelToPublish)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run {
                isLiveZoomPublishInFlight = false
                if pendingLiveZoomLevel != nil {
                    publishZoomLiveThrottled()
                }
            }
        }
    }

    private func showTemporaryControlFeedback(_ message: String) {
        captureFeedback = message
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if captureFeedback == message {
                captureFeedback = nil
            }
        }
    }

    private func armBoomerangShutter() {
        guard !isCaptureRequesting, !isSwitchingCameraDuringRecording, !isVideoRecording else { return }
        isBoomerangArmed.toggle()
        if isBoomerangArmed {
            showManualExposure = false
            showPortraitControls = false
            showZoomBar = false
            showTemporaryControlFeedback("Boomerang ready")
        } else {
            showTemporaryControlFeedback("Boomerang off")
        }
    }

    private func requestVideoPauseResume() {
        guard isVideoRecording, !isCaptureRequesting, !isSwitchingCameraDuringRecording else { return }
        let requestType = isVideoPaused ? "video_resume" : "video_pause"
        isCaptureRequesting = true
        captureFeedback = isVideoPaused ? "Resuming..." : "Pausing..."
        Task {
            do {
                try await services.roomCaptureRequester.requestCapture(roomCode: roomCode, type: requestType)
                if isVideoPaused {
                    resumeRecordingTimer()
                    isVideoPaused = false
                    captureFeedback = "Recording resumed"
                } else {
                    pauseRecordingTimer()
                    isVideoPaused = true
                    captureFeedback = "Recording paused"
                }
                isCaptureRequesting = false
            } catch {
                captureFeedback = nil
                errorMessage = error.localizedDescription
                isCaptureRequesting = false
                if requestType == "boomerang" {
                    stopBoomerangShutterProgress()
                }
            }
        }
    }

    private func requestCapture() {
        guard !suppressNextShutterTap else {
            suppressNextShutterTap = false
            return
        }
        let requestType = captureRequestType
        guard !isBurstCapturing else { return }
        guard !isCaptureRequesting else { return }
        guard !isSwitchingCameraDuringRecording || requestType == "video_stop" else { return }
        isCaptureRequesting = true
        if requestType == "boomerang" {
            isBoomerangArmed = false
            startBoomerangShutterProgress()
            captureFeedback = nil
        } else {
            captureFeedback = captureFeedbackText(for: requestType)
        }
        withAnimation(.easeOut(duration: 0.08)) {
            shutterFlashVisible = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.16)) {
                    shutterFlashVisible = false
                }
                if requestType == "photo" || requestType == "boomerang" {
                    isCaptureRequesting = false
                }
            }
        }
        Task {
            do {
                try await services.roomCaptureRequester.requestCapture(roomCode: roomCode, type: requestType)
                if requestType == "video_start" {
                    isVideoRecording = true
                    isVideoPaused = false
                    startRecordingTimer()
                    captureFeedback = "Recording started"
                } else if requestType == "video_stop" {
                    isVideoRecording = false
                    isVideoPaused = false
                    stopRecordingTimer()
                    captureFeedback = "Recording stopped"
                } else {
                    if requestType == "boomerang" {
                        isBoomerangArmed = false
                        captureFeedback = nil
                    } else {
                        incrementBurstCount()
                    }
                    let feedbackToClear = captureFeedback
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        if captureFeedback == feedbackToClear {
                            captureFeedback = nil
                        }
                    }
                    return
                }
                isCaptureRequesting = false
            } catch {
                captureFeedback = nil
                errorMessage = error.localizedDescription
                isCaptureRequesting = false
            }
        }
    }

    private var captureRequestType: String {
        if cameraMode == "video" {
            return isVideoRecording ? "video_stop" : "video_start"
        }
        if isBoomerangArmed {
            return "boomerang"
        }
        return "photo"
    }

    private func captureFeedbackText(for requestType: String) -> String {
        switch requestType {
        case "photo": return "Capture sent"
        case "boomerang": return ""
        case "video_start": return "Starting video..."
        case "video_stop": return "Stopping video..."
        default: return "Capturing..."
        }
    }

    private func startRecordingTimer() {
        videoRecordingStartedAt = Date()
        videoRecordingPausedAt = nil
        accumulatedVideoPauseDuration = 0
    }

    private func pauseRecordingTimer() {
        guard videoRecordingPausedAt == nil else { return }
        videoRecordingPausedAt = Date()
    }

    private func resumeRecordingTimer() {
        guard let videoRecordingPausedAt else { return }
        accumulatedVideoPauseDuration += Date().timeIntervalSince(videoRecordingPausedAt)
        self.videoRecordingPausedAt = nil
    }

    private func stopRecordingTimer() {
        videoRecordingStartedAt = nil
        videoRecordingPausedAt = nil
        accumulatedVideoPauseDuration = 0
    }

    private func startBoomerangShutterProgress() {
        boomerangProgressTask?.cancel()
        suppressPreviewNetworkWarningUntil = Date.now.addingTimeInterval(BoomerangCaptureDefaults.safetyTimeoutSeconds + 5.0)
        isBoomerangCaptureAnimating = true
        boomerangCaptureProgress = 0

        boomerangProgressTask = Task { @MainActor in
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(BoomerangCaptureDefaults.captureDurationMilliseconds / steps))
                guard !Task.isCancelled else { return }
                boomerangCaptureProgress = Double(step) / Double(steps)
            }
            stopBoomerangShutterProgress()
        }
    }

    private func stopBoomerangShutterProgress() {
        boomerangProgressTask?.cancel()
        boomerangProgressTask = nil
        isBoomerangCaptureAnimating = false
        boomerangCaptureProgress = 0
    }

    private func startBurstCaptureIfPossible() -> Bool {
        guard !isBurstCapturing, !isCaptureRequesting, !isSwitchingCameraDuringRecording else { return false }
        guard cameraMode == "photo" || cameraMode == "portrait" else { return false }
        guard !isBoomerangArmed, !isBoomerangCaptureAnimating, !isVideoRecording else { return false }

        let maximumBurstCaptureCount = 100
        burstCaptureTask?.cancel()
        burstResetTask?.cancel()
        burstResetTask = nil
        burstCount = 0
        isBurstCapturing = true
        captureFeedback = "Burst"
        burstCaptureTask = Task { @MainActor in
            do {
                try await services.roomCaptureRequester.requestCapture(roomCode: roomCode, type: "burst_start")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                errorMessage = error.localizedDescription
                finishControllerBurstFeedback()
                return
            }

            for _ in 0..<maximumBurstCaptureCount {
                guard !Task.isCancelled else { return }
                incrementBurstCount()
                captureFeedback = "Burst \(burstCount)"
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
        return true
    }

    private func stopBurstCapture() {
        guard isBurstCapturing else { return }
        burstCaptureTask?.cancel()
        Task {
            do {
                try await services.roomCaptureRequester.requestCapture(roomCode: roomCode, type: "burst_stop")
            } catch {
                errorMessage = error.localizedDescription
            }
            await MainActor.run {
                finishControllerBurstFeedback()
            }
        }
    }

    private func finishControllerBurstFeedback() {
        isBurstCapturing = false
        burstCaptureTask = nil
        let feedbackToClear = captureFeedback
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            if captureFeedback == feedbackToClear {
                captureFeedback = nil
            }
        }
    }

    private func incrementBurstCount() {
        burstResetTask?.cancel()
        burstCount += 1
        burstResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_300))
            guard !Task.isCancelled else { return }
            burstCount = 0
            burstResetTask = nil
        }
    }

    private func updateCameraMode(_ mode: String) {
        guard cameraMode != mode else { return }
        let shouldStopActiveVideo = cameraMode == "video" && mode != "video" && isVideoRecording
        cameraMode = mode
        isBoomerangArmed = false
        if mode != "video" {
            isVideoRecording = false
            isVideoPaused = false
            stopRecordingTimer()
        }
        if mode != "portrait" {
            showPortraitControls = false
        }
        showManualExposure = false
        showZoomBar = false
        Task {
            do {
                if shouldStopActiveVideo {
                    try await services.roomCaptureRequester.requestCapture(roomCode: roomCode, type: "video_stop")
                    captureFeedback = "Recording stopped"
                }
                try await services.roomCameraControlUpdater.updateCameraMode(roomCode: roomCode, cameraMode: mode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func endSession() {
        Task {
            do {
                try await services.roomConnectionManager.endSession(roomCode: roomCode)
                returnToStart()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func returnToStart() {
        resetControllerSessionState()
        cancelFirstFrameRetry()
        services.webRtcSession.stop()
        path = NavigationPath()
    }

    private func resetControllerSessionState() {
        controllerPreviewLensTask?.cancel()
        controllerLensSwitchTask?.cancel()
        controllerPreviewLensTarget = nil
        controllerPreviewSwitching = false
        isCaptureRequesting = false
        isSwitchingCameraDuringRecording = false
        isVideoRecording = false
        isVideoPaused = false
        stopRecordingTimer()
        isBoomerangArmed = false
        isBurstCapturing = false
        burstCaptureTask?.cancel()
        burstCaptureTask = nil
        suppressPreviewNetworkWarningUntil = Date.distantPast
        stopBoomerangShutterProgress()
        burstResetTask?.cancel()
        burstResetTask = nil
        burstCount = 0
        captureFeedback = nil
    }

    private func updateGridEnabled(_ enabled: Bool) {
        Task {
            do {
                try await services.roomCameraControlUpdater.updateGridEnabled(roomCode: roomCode, gridEnabled: enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateVideoHdrEnabled(_ enabled: Bool) {
        Task {
            do {
                try await services.roomCameraControlUpdater.updateVideoHdrEnabled(roomCode: roomCode, videoHdrEnabled: enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateNightModeEnabled(_ enabled: Bool) {
        Task {
            do {
                try await services.roomCameraControlUpdater.updateNightModeEnabled(roomCode: roomCode, nightModeEnabled: enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updatePortraitControls(strength: Int, effect: String) {
        Task {
            do {
                try await services.roomCameraControlUpdater.updatePortraitControls(
                    roomCode: roomCode,
                    blurLevel: room?.portraitBlurLevel ?? "blur",
                    strength: strength,
                    effect: effect
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateSceneDetectionEnabled(_ enabled: Bool) {
        Task {
            do {
                try await services.roomCameraControlUpdater.updateSceneDetectionEnabled(roomCode: roomCode, sceneDetectionEnabled: enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncAspectRatioModeFromRoom(_ mode: String) {
        let safeMode = RoomSchema.safeAspectRatioMode(mode)
        if pendingAspectRatioMode == safeMode {
            pendingAspectRatioMode = nil
        }
        guard pendingAspectRatioMode == nil else { return }
        aspectRatioMode = safeMode
    }

    private func updateControllerToolRailExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isControllerToolRailExpanded = expanded
        }
        Task { try? await services.roomCameraControlUpdater.updateToolbarExpanded(roomCode: roomCode, toolbarExpanded: expanded) }
    }

    private func syncControllerToolRailExpandedFromRoom(_ expanded: Bool) {
        guard isControllerToolRailExpanded != expanded else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isControllerToolRailExpanded = expanded
        }
    }

    private func updateAspectRatioMode(_ mode: String) {
        let safeMode = RoomSchema.safeAspectRatioMode(mode)
        pendingAspectRatioMode = safeMode
        aspectRatioMode = safeMode
        Task {
            do {
                try await services.roomCameraControlUpdater.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: safeMode)
            } catch {
                pendingAspectRatioMode = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendFocusRequest(sourcePoint: CGPoint, displayPoint: CGPoint) {
        focusReticlePoint = displayPoint
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            if focusReticlePoint == displayPoint {
                focusReticlePoint = nil
            }
        }
        Task {
            do {
                try await services.roomCameraControlUpdater.updateFocusRequest(
                    roomCode: roomCode,
                    x: sourcePoint.x,
                    y: sourcePoint.y,
                    requestId: Int64(Date().timeIntervalSince1970 * 1000),
                    lockEnabled: false
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publishExposureDebounced(_ value: Double) {
        exposurePublishTask?.cancel()
        exposurePublishTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            do {
                try await services.roomCameraControlUpdater.updateExposureIndex(
                    roomCode: roomCode,
                    exposureIndex: Int((value * 8.0).rounded())
                )
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct AndroidControlButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 58
    var tint: Color = .white
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .frame(width: size, height: size)
                    .foregroundStyle(isSelected ? .black : tint)
                    .background(isSelected ? tint : Color.black.opacity(0.52), in: Circle())
                    .overlay(Circle().stroke(tint.opacity(isSelected ? 0.65 : 0.22), lineWidth: 1))

                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
    }
}

private struct ControllerTopStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.58, green: 0.34, blue: 1.0))
                .frame(width: 7, height: 7)
                .shadow(color: Color(red: 0.58, green: 0.34, blue: 1.0).opacity(0.85), radius: 5)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.54), in: Capsule())
        .overlay(Capsule().stroke(Color(red: 0.58, green: 0.34, blue: 1.0).opacity(0.34), lineWidth: 1))
    }
}

private struct ControllerRoomCodeCard: View {
    let roomCode: String

    private var spacedRoomCode: String {
        roomCode.map(String.init).joined(separator: " ")
    }

    var body: some View {
        Text(spacedRoomCode)
            .font(.system(size: 18, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.08, blue: 0.24).opacity(0.88),
                        Color.black.opacity(0.58)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(red: 0.58, green: 0.34, blue: 1.0).opacity(0.46), lineWidth: 1))
            .shadow(color: Color(red: 0.36, green: 0.18, blue: 1.0).opacity(0.24), radius: 16, y: 6)
    }
}

private struct ControllerEndButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .black))
                Text("End")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Color(red: 1.0, green: 0.34, blue: 0.42))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.54), in: Capsule())
            .overlay(Capsule().stroke(Color(red: 1.0, green: 0.34, blue: 0.42).opacity(0.42), lineWidth: 1))
            .shadow(color: Color(red: 1.0, green: 0.18, blue: 0.30).opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct ControllerRailButton: View {
    let systemName: String
    let label: String
    var role: ButtonRole?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isSelected ? .black : .white)
                    .background(isSelected ? Color.white : Color.white.opacity(0.11), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 40)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ControllerVideoRectOverlay<Content: View>: View {
    let videoDrawRect: CGRect
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: videoDrawRect.width, height: videoDrawRect.height)
            .clipped()
            .position(x: videoDrawRect.midX, y: videoDrawRect.midY)
            .allowsHitTesting(false)
    }
}

private struct ControllerPortraitSubjectOverlay: View {
    let state: PortraitSubjectState
    let faceDetectionState: FaceDetectionOverlayState
    let videoDrawRect: CGRect
    let isMirrored: Bool

    private static let staleDetectionIntervalMillis: Int64 = 1_200

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            GeometryReader { geometry in
                let isVisible = state.faceBounds.isValid && faceDetectionState.detected && isFresh(at: timeline.date)
                let rect = displayRect(for: state.faceBounds, canvasSize: geometry.size)
                ZStack(alignment: .topLeading) {
                    if isVisible {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)

                        Text(state.status)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.46), in: Capsule())
                            .position(x: videoDrawRect.midX, y: min(videoDrawRect.maxY - 22, max(videoDrawRect.minY + 22, rect.maxY + 18)))
                    }
                }
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func isFresh(at date: Date) -> Bool {
        guard faceDetectionState.timestamp > 0 else { return false }
        let nowMillis = Int64(date.timeIntervalSince1970 * 1000)
        return nowMillis - faceDetectionState.timestamp <= Self.staleDetectionIntervalMillis
    }

    private func displayRect(for box: NormalizedFaceBounds, canvasSize: CGSize) -> CGRect {
        guard box.isValid else {
            return CGRect(x: videoDrawRect.midX - 1, y: videoDrawRect.midY - 1, width: 2, height: 2)
        }
        let left = CGFloat(isMirrored ? 1.0 - box.right : box.left)
        let right = CGFloat(isMirrored ? 1.0 - box.left : box.right)
        let rect = CGRect(
            x: videoDrawRect.minX + left * videoDrawRect.width,
            y: videoDrawRect.minY + CGFloat(box.top) * videoDrawRect.height,
            width: max(0, (right - left) * videoDrawRect.width),
            height: max(0, CGFloat(box.bottom - box.top) * videoDrawRect.height)
        )
        return rect.intersection(CGRect(origin: .zero, size: canvasSize))
    }
}

private struct ControllerFaceOverlay: View {
    let state: FaceDetectionOverlayState
    let videoDrawRect: CGRect
    let isMirrored: Bool

    private static let staleDetectionIntervalMillis: Int64 = 1_200

    private func boxes(at date: Date) -> [NormalizedFaceBounds] {
        guard state.detected, isFresh(at: date) else { return [] }
        let validBoxes = state.boxes.filter(\.isValid)
        if !validBoxes.isEmpty { return validBoxes }
        return state.primaryBox.isValid ? [state.primaryBox] : []
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            GeometryReader { geometry in
                let visibleBoxes = boxes(at: timeline.date)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(visibleBoxes.enumerated()), id: \.offset) { _, box in
                        let rect = displayRect(for: box, canvasSize: geometry.size)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.yellow, lineWidth: 1.5)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func isFresh(at date: Date) -> Bool {
        guard state.timestamp > 0 else { return false }
        let nowMillis = Int64(date.timeIntervalSince1970 * 1000)
        return nowMillis - state.timestamp <= Self.staleDetectionIntervalMillis
    }

    private func displayRect(for box: NormalizedFaceBounds, canvasSize: CGSize) -> CGRect {
        let left = CGFloat(isMirrored ? 1.0 - box.right : box.left)
        let right = CGFloat(isMirrored ? 1.0 - box.left : box.right)
        let top = CGFloat(box.top)
        let bottom = CGFloat(box.bottom)
        let rect = CGRect(
            x: videoDrawRect.minX + left * videoDrawRect.width,
            y: videoDrawRect.minY + top * videoDrawRect.height,
            width: max(0, (right - left) * videoDrawRect.width),
            height: max(0, (bottom - top) * videoDrawRect.height)
        )
        return rect.intersection(CGRect(origin: .zero, size: canvasSize))
    }
}

private struct ControllerPreviewConnectionOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18), lineWidth: 1))
        .allowsHitTesting(false)
    }
}
