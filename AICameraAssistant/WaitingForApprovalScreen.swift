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
    @State private var isVideoRecording = false
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
            ZStack {
                Color.black

                ZStack {
                    #if canImport(WebRTC)
                    if let remoteVideoTrack = services.webRtcSession.remoteVideoTrack {
                        let isSwitchingLens = controllerPreviewSwitching
                        RemoteVideoView(track: remoteVideoTrack, isMirrored: controllerPreviewLensFacing == .front)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .overlay {
                                if isSwitchingLens {
                                    CameraSwitchingOverlay()
                                }
                            }
                    } else {
                        previewStatusOverlay
                    }
                    #else
                    previewStatusOverlay
                    #endif
                }
                .overlay {
                    if room?.gridEnabled == true {
                        CameraGridOverlay()
                    }
                }
                .overlay {
                    GeometryReader { previewGeometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        guard room?.controllerApproved == true else { return }
                                        let x = min(1.0, max(0.0, value.location.x / max(previewGeometry.size.width, 1)))
                                        let y = min(1.0, max(0.0, value.location.y / max(previewGeometry.size.height, 1)))
                                        sendFocusRequest(x: x, y: y)
                                    }
                            )
                    }
                }
                .overlay {
                    if let focusReticlePoint {
                        FocusExposureOverlay(
                            point: focusReticlePoint,
                            exposureValue: $exposureValue,
                            isInteractive: true,
                            onExposureCommitted: publishExposureDebounced
                        )
                    }
                }
                .cameraPreviewFrame(aspectRatioMode: room?.aspectRatioMode ?? "full")
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
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
        VStack(spacing: 14) {
            if showManualExposure {
                manualExposurePanel
            } else if showPortraitControls && cameraMode == "portrait" {
                portraitControlsPanel
            } else if showZoomBar {
                zoomStrip
            } else {
                zoomPresetStrip
            }

            if isVideoRecording {
                recordingControls
            } else {
                HStack(spacing: 34) {
                    if cameraMode == "video" {
                        videoHdrButton
                    } else {
                        portraitToggleButton
                    }

                    shutterButton

                    CameraCircleButton(
                        systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill",
                        size: 58
                    ) {
                        switchControllerLens()
                    }
                }
            }

            HStack(spacing: 18) {
                modeButton("video", label: "Video")
                modeButton("photo", label: "Photo")
                modeButton("portrait", label: "Portrait")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.42), in: Capsule())

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
        HStack(spacing: 22) {
            CameraCircleButton(systemName: "stop.fill", size: 64, role: .destructive) {
                requestCapture()
            }

            CameraCircleButton(
                systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill",
                size: 54
            ) {
                switchControllerLens()
            }
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
                .fontWeight(cameraMode == mode ? .semibold : .medium)
                .foregroundStyle(cameraMode == mode ? .yellow : .white.opacity(0.55))
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

            CameraCircleButton(systemName: "aspectratio") {
                updateAspectRatioMode((room?.aspectRatioMode ?? "full").nextCameraAspectRatioMode)
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
                    captureFeedback = "Recording started"
                } else if requestType == "video_stop" {
                    isVideoRecording = false
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

    private func updateAspectRatioMode(_ mode: String) {
        Task {
            do {
                try await services.roomRepository.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: mode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendFocusRequest(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        focusReticlePoint = point
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            if focusReticlePoint == point {
                focusReticlePoint = nil
            }
        }
        Task {
            do {
                try await services.roomRepository.updateFocusRequest(
                    roomCode: roomCode,
                    x: x,
                    y: y,
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
