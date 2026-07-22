import SwiftUI

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

    var body: some View {
        ZStack {
            previewSurface
                .ignoresSafeArea()

            VStack {
                controllerTopBar
                Spacer()
                if room?.controllerApproved == true {
                    controllerControls
                } else {
                    approvalStatus
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if room?.controllerApproved == true {
                HStack {
                    Spacer()
                    controllerToolRail
                }
                .padding(.trailing, 16)
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
                guard layout.localBounds.contains(localPoint) else { return }
                sendFocusRequest(
                    sourcePoint: layout.sourcePoint(for: localPoint),
                    displayPoint: layout.displayPoint(for: localPoint)
                )
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
                CameraGridOverlay()
            }

            if let room {
                ControllerFaceOverlay(
                    state: room.faceDetectionOverlayState,
                    videoDrawRect: layout.videoDrawRectInVisibleRect,
                    isMirrored: controllerPreviewLensFacing == .front
                )
            }

            if let focusReticlePoint {
                FocusExposureOverlay(
                    point: focusReticlePoint,
                    exposureValue: $exposureValue,
                    isInteractive: true,
                    onExposureChanged: publishExposureDebounced,
                    onExposureCommitted: publishExposureDebounced,
                    onInteractionChanged: updateFocusTapSuppression
                )
            }

            if let message = previewConnectionOverlayText {
                ControllerPreviewConnectionOverlay(message: message)
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
        HStack {
            CameraStatusPill(primary: "Room \(roomCode)", secondary: statusText)
            Spacer()
        }
    }

    private var approvalStatus: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.white)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var previewConnectionOverlayText: String? {
        guard room?.controllerApproved == true else { return nil }
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
            controllerModeStrip
            controllerPrimaryControls
            controllerStatusOverlays
        }
        .frame(maxWidth: 430)
    }

    @ViewBuilder
    private var controllerAccessoryPanel: some View {
        if showManualExposure {
            manualExposurePanel
        } else if showPortraitControls && cameraMode == "portrait" {
            portraitControlsPanel
        } else if showZoomBar {
            zoomStrip
        } else {
            zoomPresetStrip
        }
    }

    private var controllerModeStrip: some View {
        HStack(spacing: 6) {
            modeButton("video", label: "VIDEO")
            modeButton("photo", label: "PHOTO")
            modeButton("portrait", label: "PORTRAIT")
        }
        .padding(4)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var controllerPrimaryControls: some View {
        HStack(alignment: .center, spacing: 18) {
            controllerLeftActions
                .frame(width: 86)

            Spacer(minLength: 0)

            if isVideoRecording {
                recordingControls
            } else {
                VStack(spacing: 8) {
                    captureModeBadge
                    shutterButton
                    burstCountPill
                }
            }

            Spacer(minLength: 0)

            controllerRightActions
                .frame(width: 86)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var controllerLeftActions: some View {
        VStack(spacing: 12) {
            if cameraMode == "video" {
                videoHdrButton
            } else {
                portraitToggleButton
            }
            boomerangButton
        }
    }

    private var controllerRightActions: some View {
        VStack(spacing: 12) {
            lensFlipButton(size: 58)
            CameraCircleButton(systemName: "plus.magnifyingglass", size: 46, isSelected: showZoomBar) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showManualExposure = false
                    showPortraitControls = false
                    showZoomBar.toggle()
                }
            }
        }
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
        HStack(spacing: 10) {
            ForEach(commonZoomOptions, id: \.self) { option in
                let isSelected = abs(zoomLevel - option) < 0.08
                Button {
                    zoomLevel = option
                    publishControls()
                } label: {
                    Text(String(format: option.truncatingRemainder(dividingBy: 1) == 0 ? "%.0fx" : "%.1fx", option))
                        .font(.caption.monospacedDigit().weight(isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(minWidth: 42, minHeight: 34)
                        .background(isSelected ? Color.white : Color.black.opacity(0.5), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.18)) { showZoomBar = true }
                })
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.36), in: Capsule())
    }

    private var commonZoomOptions: [Double] {
        let maximumZoom = room?.maxZoom ?? 8.0
        return [1.0, 2.0, 3.0, 5.0].filter { $0 <= max(maximumZoom, 1.0) }
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
                .onChange(of: exposureValue) { value in publishExposureDebounced(value) }
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
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                CameraCircleButton(systemName: isVideoPaused ? "play.fill" : "pause.fill", size: 50) {
                    requestVideoPauseResume()
                }
                CameraCircleButton(systemName: "stop.fill", size: 72, role: .destructive) {
                    requestCapture()
                }
                lensFlipButton(size: 50)
            }
            Text("VIDEO")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        }
    }

    private var lensFlipButton: some View {
        lensFlipButton(size: 58)
    }

    private func lensFlipButton(size: CGFloat) -> some View {
        CameraCircleButton(
            systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill",
            size: size
        ) {
            switchControllerLens()
        }
    }

    private var boomerangButton: some View {
        CameraCircleButton(systemName: "infinity", size: 46) {
            showTemporaryControlFeedback("Boomerang next")
        }
    }

    private var captureModeBadge: some View {
        Text(cameraModeDisplayLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(cameraMode == "video" ? .red : .yellow)
            .frame(height: 14)
    }

    private var burstCountPill: some View {
        Text("1x")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.36), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var cameraModeDisplayLabel: String {
        switch cameraMode {
        case "video": return isVideoRecording ? "REC" : "VIDEO"
        case "portrait": return "PORTRAIT"
        default: return "PHOTO"
        }
    }

    private var recordingStatusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Text("Recording")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.48), in: Capsule())
    }

    private var portraitToggleButton: some View {
        CameraCircleButton(
            systemName: "person.crop.rectangle",
            size: 58,
            isSelected: showPortraitControls && cameraMode == "portrait"
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
        CameraCircleButton(
            systemName: "h.square",
            size: 58,
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
                .frame(minWidth: 78, minHeight: 30)
                .background(cameraMode == mode ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var controllerToolRail: some View {
        VStack(spacing: 14) {
            CameraCircleButton(systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill") {
                switchControllerLens()
            }

            CameraCircleButton(
                systemName: flashMode.cameraFlashIconName,
                isSelected: flashMode != "off"
            ) {
                flashMode = flashMode.nextCameraFlashMode
                publishControls()
            }

            CameraCircleButton(systemName: "sun.max", isSelected: showManualExposure) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showZoomBar = false
                    showPortraitControls = false
                    showManualExposure.toggle()
                }
            }

            CameraCircleButton(systemName: "sparkles", isSelected: room?.sceneDetectionEnabled == true) {
                updateSceneDetectionEnabled(!(room?.sceneDetectionEnabled ?? false))
            }

            CameraCircleButton(systemName: "square.grid.3x3", isSelected: room?.gridEnabled == true) {
                updateGridEnabled(!(room?.gridEnabled ?? false))
            }

            VStack(spacing: 4) {
                CameraCircleButton(systemName: "aspectratio") {
                    updateAspectRatioMode(aspectRatioMode.nextCameraAspectRatioMode)
                }
                Text(aspectRatioMode.cameraAspectRatioLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            CameraCircleButton(systemName: "xmark.circle", role: .destructive) {
                endSession()
            }

        }
        .padding(.vertical, 10)
    }

    private var zoomStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus.magnifyingglass")
            Slider(value: $zoomLevel, in: 1.0...8.0, step: 0.1)
                .onChange(of: zoomLevel) { _ in publishZoomDebounced() }
            Text(String(format: "%.1fx", zoomLevel))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.52), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private var shutterButton: some View {
        Button { requestCapture() } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(shutterFillColor)
                    .frame(width: isCaptureRequesting ? 58 : 64, height: isCaptureRequesting ? 58 : 64)
            }
            .animation(.easeOut(duration: 0.12), value: isCaptureRequesting)
        }
        .buttonStyle(.plain)
        .disabled(isCaptureRequesting || isSwitchingCameraDuringRecording || room?.status == .ended)
        .accessibilityLabel(cameraMode == "video" ? "Record video" : "Capture photo")
    }

    private var shutterFillColor: Color {
        if cameraMode == "video" {
            return isVideoRecording ? .red : .white
        }
        return isCaptureRequesting ? .white.opacity(0.72) : .white
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
            for try await nextRoom in await services.roomRepository.observeRoom(roomCode: roomCode) {
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
                zoomLevel = nextRoom.zoomLevel
                flashMode = nextRoom.flashMode.safeCameraFlashMode
                cameraMode = nextRoom.cameraMode
                syncAspectRatioModeFromRoom(nextRoom.aspectRatioMode)
                exposureValue = Double(nextRoom.exposureIndex) / 8.0
                if !didPrewarmControllerStream {
                    didPrewarmControllerStream = true
                    await services.webRtcSession.startController(roomCode: roomCode, repository: services.roomRepository)
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
                    try await services.roomRepository.updateControls(
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
                try await services.roomRepository.updateControls(roomCode: roomCode, lensFacing: lensFacing, zoomLevel: zoomLevel, flashMode: flashMode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publishZoomDebounced() {
        zoomPublishTask?.cancel()
        zoomPublishTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try await services.roomRepository.updateControls(roomCode: roomCode, lensFacing: lensFacing, zoomLevel: zoomLevel, flashMode: flashMode)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
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

    private func requestVideoPauseResume() {
        guard isVideoRecording, !isCaptureRequesting, !isSwitchingCameraDuringRecording else { return }
        let requestType = isVideoPaused ? "video_resume" : "video_pause"
        isCaptureRequesting = true
        captureFeedback = isVideoPaused ? "Resuming..." : "Pausing..."
        Task {
            do {
                try await services.roomRepository.requestCapture(roomCode: roomCode, type: requestType)
                isVideoPaused.toggle()
                captureFeedback = isVideoPaused ? "Recording paused" : "Recording resumed"
                isCaptureRequesting = false
            } catch {
                captureFeedback = nil
                errorMessage = error.localizedDescription
                isCaptureRequesting = false
            }
        }
    }

    private func requestCapture() {
        let requestType = captureRequestType
        guard !isCaptureRequesting else { return }
        guard !isSwitchingCameraDuringRecording || requestType == "video_stop" else { return }
        isCaptureRequesting = true
        captureFeedback = requestType == "photo" ? "Capture sent" : "Capturing..."
        withAnimation(.easeOut(duration: 0.08)) {
            shutterFlashVisible = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.16)) {
                    shutterFlashVisible = false
                }
                if requestType == "photo" {
                    isCaptureRequesting = false
                }
            }
        }
        Task {
            do {
                try await services.roomRepository.requestCapture(roomCode: roomCode, type: requestType)
                if requestType == "video_start" {
                    isVideoRecording = true
                    isVideoPaused = false
                    captureFeedback = "Recording started"
                } else if requestType == "video_stop" {
                    isVideoRecording = false
                    isVideoPaused = false
                    captureFeedback = "Recording stopped"
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        if captureFeedback == "Capture sent" {
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
        return "photo"
    }

    private func updateCameraMode(_ mode: String) {
        guard cameraMode != mode else { return }
        let shouldStopActiveVideo = cameraMode == "video" && mode != "video" && isVideoRecording
        cameraMode = mode
        if mode != "video" {
            isVideoRecording = false
            isVideoPaused = false
        }
        if mode != "portrait" {
            showPortraitControls = false
        }
        showManualExposure = false
        showZoomBar = false
        Task {
            do {
                if shouldStopActiveVideo {
                    try await services.roomRepository.requestCapture(roomCode: roomCode, type: "video_stop")
                    captureFeedback = "Recording stopped"
                }
                try await services.roomRepository.updateCameraMode(roomCode: roomCode, cameraMode: mode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func endSession() {
        Task {
            do {
                try await services.roomRepository.endSession(roomCode: roomCode)
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
        captureFeedback = nil
    }

    private func updateGridEnabled(_ enabled: Bool) {
        Task {
            do {
                try await services.roomRepository.updateGridEnabled(roomCode: roomCode, gridEnabled: enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateVideoHdrEnabled(_ enabled: Bool) {
        Task {
            do {
                try await services.roomRepository.updateVideoHdrEnabled(roomCode: roomCode, videoHdrEnabled: enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updatePortraitControls(strength: Int, effect: String) {
        Task {
            do {
                try await services.roomRepository.updatePortraitControls(
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
                try await services.roomRepository.updateSceneDetectionEnabled(roomCode: roomCode, sceneDetectionEnabled: enabled)
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

    private func updateAspectRatioMode(_ mode: String) {
        let safeMode = RoomSchema.safeAspectRatioMode(mode)
        pendingAspectRatioMode = safeMode
        aspectRatioMode = safeMode
        Task {
            do {
                try await services.roomRepository.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: safeMode)
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
                try await services.roomRepository.updateFocusRequest(
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
                try await services.roomRepository.updateExposureIndex(
                    roomCode: roomCode,
                    exposureIndex: Int((value * 8.0).rounded())
                )
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct ControllerPreviewLayout {
    let containerSize: CGSize
    let aspectRatioMode: String
    let sourceWidth: Int
    let sourceHeight: Int

    var visibleRect: CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        guard aspectRatioMode != "full" else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let targetAspect = aspectRatioMode.cameraPreviewAspectRatio
        let containerAspect = containerSize.width / max(containerSize.height, 1)
        let size: CGSize
        if containerAspect > targetAspect {
            size = CGSize(width: containerSize.height * targetAspect, height: containerSize.height)
        } else {
            size = CGSize(width: containerSize.width, height: containerSize.width / targetAspect)
        }
        return CGRect(
            x: (containerSize.width - size.width) / 2.0,
            y: (containerSize.height - size.height) / 2.0,
            width: size.width,
            height: size.height
        )
    }

    var localBounds: CGRect {
        CGRect(origin: .zero, size: visibleRect.size)
    }

    var videoDrawRectInVisibleRect: CGRect {
        let bounds = localBounds
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let sourceAspect = CGFloat(sourceWidth > 0 && sourceHeight > 0 ? Double(sourceWidth) / Double(sourceHeight) : 16.0 / 9.0)
        let boundsAspect = bounds.width / max(bounds.height, 1)
        let size: CGSize
        if boundsAspect > sourceAspect {
            size = CGSize(width: bounds.width, height: bounds.width / sourceAspect)
        } else {
            size = CGSize(width: bounds.height * sourceAspect, height: bounds.height)
        }
        return CGRect(
            x: (bounds.width - size.width) / 2.0,
            y: (bounds.height - size.height) / 2.0,
            width: size.width,
            height: size.height
        )
    }

    func sourcePoint(for localPoint: CGPoint) -> CGPoint {
        let videoRect = videoDrawRectInVisibleRect
        guard videoRect.width > 0, videoRect.height > 0 else { return .zero }
        return CGPoint(
            x: min(1.0, max(0.0, (localPoint.x - videoRect.minX) / videoRect.width)),
            y: min(1.0, max(0.0, (localPoint.y - videoRect.minY) / videoRect.height))
        )
    }

    func displayPoint(for localPoint: CGPoint) -> CGPoint {
        let bounds = localBounds
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: min(1.0, max(0.0, localPoint.x / bounds.width)),
            y: min(1.0, max(0.0, localPoint.y / bounds.height))
        )
    }
}

private struct ControllerFaceOverlay: View {
    let state: FaceDetectionOverlayState
    let videoDrawRect: CGRect
    let isMirrored: Bool

    private var boxes: [NormalizedFaceBounds] {
        let validBoxes = state.boxes.filter(\.isValid)
        if !validBoxes.isEmpty { return validBoxes }
        return state.primaryBox.isValid ? [state.primaryBox] : []
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    let rect = displayRect(for: box, canvasSize: geometry.size)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .clipped()
        }
        .allowsHitTesting(false)
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
