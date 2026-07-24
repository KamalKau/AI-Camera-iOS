import SwiftUI

struct CameraHostScreen: View {
    let roomCode: String
    @Binding var path: NavigationPath

    @EnvironmentObject private var services: AppServices
    @StateObject private var camera = CameraController()
    @State private var room: RoomDocument?
    @State private var errorMessage: String?
    @State private var lastHandledCaptureRequestId: Int64?
    @State private var isHandlingRemoteCapture = false
    @State private var lastHandledFocusRequestId: Int64 = 0
    @State private var lastAppliedExposureIndex: Int?
    @State private var focusReticlePoint: CGPoint?
    @State private var exposureValue = 0.0
    @State private var aspectRatioMode = RoomSchema.defaultAspectRatioMode
    @State private var pendingAspectRatioMode: String?
    @State private var isPrewarmingHostStream = false
    @State private var hostPreviewLensFacing: LensFacing = .back
    @State private var hostPreviewLensTask: Task<Void, Never>?
    @State private var hostPreviewLensTarget: LensFacing?
    @State private var hostPreviewSwitching = false
    @State private var hostPreviewSwitchTask: Task<Void, Never>?
    @State private var isHostToolRailExpanded = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                hostPreview

                VStack(spacing: 0) {
                    hostTopOverlay
                    Spacer(minLength: 0)
                    hostBottomOverlay
                }
                .padding(.horizontal, 16)
                .padding(.top, max(4, geometry.safeAreaInsets.top + 2))
                .padding(.bottom, max(16, geometry.safeAreaInsets.bottom + 12))

                if shouldShowApprovalPanel {
                    approvalPanel
                        .padding(.horizontal, 22)
                        .zIndex(8)
                }

                ZStack {
                    HostTopStatusPill(text: statusText)
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer(minLength: 0)
                        HostEndButton {
                            endSession()
                        }
                    }
                }
                .frame(width: max(0, geometry.size.width - 28))
                .position(x: geometry.size.width / 2, y: 18)
                .zIndex(10)

                HStack {
                    Spacer(minLength: 0)
                    hostToolRail
                }
                .padding(.trailing, 14)
                .padding(.top, max(82, geometry.safeAreaInsets.top + 92))
                .padding(.bottom, max(132, geometry.safeAreaInsets.bottom + 132))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black.ignoresSafeArea())
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await camera.requestPermissionAndStart()
            await observeRoom()
        }
        .onDisappear {
            hostPreviewLensTask?.cancel()
            hostPreviewSwitchTask?.cancel()
            Task {
                await services.webRtcSession.finishHostVideoRecordingBeforeTeardown()
                camera.stop()
                services.webRtcSession.stop()
            }
        }
    }

    @ViewBuilder
    private var hostPreview: some View {
        ZStack {
            Color.black

            ZStack {
                let requestedLensFacing = room?.lensFacing ?? camera.lensFacing
                let previewLensFacing = services.webRtcSession.localVideoTrack == nil ? requestedLensFacing : services.webRtcSession.capturedLensFacing
                #if canImport(WebRTC)
                if let localVideoTrack = services.webRtcSession.localVideoTrack {
                    let isSwitchingLens = hostPreviewSwitching
                    RemoteVideoView(track: localVideoTrack, isMirrored: previewLensFacing == .front)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        .overlay {
                            if isSwitchingLens {
                                CameraSwitchingOverlay()
                            }
                        }
                } else {
                    CameraPreviewView(session: camera.session, lensFacing: previewLensFacing)
                        .id(previewLensFacing)
                }
                #else
                CameraPreviewView(session: camera.session, lensFacing: previewLensFacing)
                    .id(previewLensFacing)
                #endif
            }
            .overlay {
                if room?.gridEnabled == true {
                    CameraGridOverlay()
                }
            }
            .overlay {
                if let focusReticlePoint {
                    FocusExposureOverlay(point: focusReticlePoint, exposureValue: $exposureValue)
                }
            }
            .cameraPreviewFrame(aspectRatioMode: aspectRatioMode)
            .clipped()
            .id(aspectRatioMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var hostTopOverlay: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                HostRoomStatusCard(roomCode: roomCode, statusText: statusText)
                    .frame(maxWidth: 230)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if services.webRtcSession.isHostVideoRecording {
                        HostRecordingPill(isPaused: services.webRtcSession.isHostVideoPaused)
                    }
                }
            }

            if let hostInsightText {
                HostInfoChip(text: hostInsightText, systemName: room?.sceneDetectionEnabled == true ? "sparkles" : "person.crop.rectangle")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var hostToolRail: some View {
        VStack(spacing: 12) {
            HostRailButton(
                systemName: camera.flashMode.cameraFlashIconName,
                label: camera.flashMode.cameraFlashLabel,
                isSelected: camera.flashMode != "off"
            ) {
                camera.flashMode = camera.flashMode.nextCameraFlashMode
                updateFlashMode(camera.flashMode)
            }

            HostRailButton(systemName: "square.grid.3x3", label: "Grid", isSelected: room?.gridEnabled == true) {
                updateGridEnabled(!(room?.gridEnabled ?? false))
            }

            HostRailButton(systemName: "aspectratio", label: aspectRatioMode.cameraAspectRatioLabel) {
                updateAspectRatioMode(aspectRatioMode.nextCameraAspectRatioMode)
            }

            if isHostToolRailExpanded {
                HostRailButton(systemName: "circle.grid.cross", label: "Boom", isSelected: false) {}

                HostRailButton(systemName: "sparkles", label: "Scene", isSelected: room?.sceneDetectionEnabled == true) {
                    updateSceneDetectionEnabled(!(room?.sceneDetectionEnabled ?? false))
                }

                HostRailButton(systemName: "moon.stars", label: "Night", isSelected: room?.nightModeEnabled == true) {
                    updateNightModeEnabled(!(room?.nightModeEnabled ?? false))
                }

                HostRailButton(systemName: "h.square", label: "HDR", isSelected: room?.videoHdrEnabled == true) {
                    updateVideoHdrEnabled(!(room?.videoHdrEnabled ?? false))
                }

            }

            HostRailButton(systemName: isHostToolRailExpanded ? "chevron.up" : "ellipsis", label: isHostToolRailExpanded ? "Less" : "More") {
                updateToolbarExpanded(!isHostToolRailExpanded)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.46), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .animation(.easeInOut(duration: 0.18), value: isHostToolRailExpanded)
    }

    private var hostBottomOverlay: some View {
        VStack(spacing: 12) {
            if camera.permissionState == .denied {
                HostWarningChip(text: "Camera permission is required to host a room.")
            }

            hostCaptureControls

            if let errorMessage {
                HostWarningChip(text: errorMessage)
            }

            if let photoSaveMessage = camera.photoSaveMessage {
                HostInfoChip(text: photoSaveMessage, systemName: "checkmark.circle")
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var approvalPanel: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.52, green: 0.31, blue: 1.0), Color(red: 0.20, green: 0.48, blue: 1.0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                    .shadow(color: Color(red: 0.45, green: 0.24, blue: 1.0).opacity(0.42), radius: 18, y: 8)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 7) {
                Text("Controller wants to join")
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Allow this device to control the camera and view the live preview.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            HStack(spacing: 12) {
                HostApprovalActionButton(title: "Deny", systemName: "xmark", style: .deny) {
                    updateApproval(approved: false)
                }

                HostApprovalActionButton(title: "Allow", systemName: "checkmark", style: .allow) {
                    updateApproval(approved: true)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: 360)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.07, blue: 0.21).opacity(0.94),
                    Color.black.opacity(0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(red: 0.53, green: 0.32, blue: 1.0).opacity(0.50), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
    }

    private var hostModeStrip: some View {
        HStack(spacing: 0) {
            hostModeButton("video", label: "VIDEO")
            hostModeButton("photo", label: "PHOTO")
            hostModeButton("portrait", label: "PORTRAIT")
        }
        .padding(4)
        .background(Color.black.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var hostCaptureControls: some View {
        ZStack {
            hostModeStrip
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer(minLength: 0)
                hostFlipCameraButton
            }
        }
        .frame(maxWidth: 320)
        .padding(.bottom, 10)
        .offset(y: 8)
    }

    private var hostFlipCameraButton: some View {
        CameraCircleButton(systemName: camera.lensFacing == .back ? "camera.rotate" : "camera.rotate.fill", size: 48) {
            switchHostLens()
        }
    }

    private func hostModeButton(_ mode: String, label: String) -> some View {
        Button { updateCameraMode(mode) } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle((room?.cameraMode ?? "photo") == mode ? .black : .white.opacity(0.68))
                .frame(minWidth: 64, minHeight: 30)
                .background((room?.cameraMode ?? "photo") == mode ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        guard let room else { return "Waiting for room updates" }
        switch room.status {
        case .created: return "Waiting for controller"
        case .waitingForApproval: return "Controller is requesting access"
        case .connected:
            return services.webRtcSession.state == .connected ? "Controller connected" : "Starting live preview"
        case .denied: return "Controller denied"
        case .disconnected: return "Disconnected"
        case .ended: return "Session ended"
        }
    }

    private var shouldShowApprovalPanel: Bool {
        room?.requestReceived == true && room?.controllerApproved == false && room?.status == .waitingForApproval
    }

    private var hostInsightText: String? {
        guard let room else { return nil }
        if room.cameraMode == "portrait" {
            return "Portrait \(room.portraitEffect.replacingOccurrences(of: "_", with: " ").capitalized) \(room.portraitStrength)/7"
        }
        if room.sceneDetectionEnabled {
            let label = room.sceneDetection.label.isEmpty ? "Scene detection ready" : room.sceneDetection.label
            return room.sceneDetection.suggestion.isEmpty ? label : "\(label): \(room.sceneDetection.suggestion)"
        }
        return nil
    }

    private func observeRoom() async {
        do {
            for try await nextRoom in await services.roomRepository.observeRoom(roomCode: roomCode) {
                room = nextRoom
                hostPreviewLensTask?.cancel()
                hostPreviewLensFacing = services.webRtcSession.capturedLensFacing
                if nextRoom.status == .ended {
                    await returnToStart()
                    return
                }
                if nextRoom.status == .denied {
                    services.webRtcSession.stop()
                    await camera.requestPermissionAndStart()
                    continue
                }
                services.webRtcSession.applyStreamQualityMode(nextRoom.streamQualityMode)
                if services.webRtcSession.state == .idle {
                    camera.apply(lensFacing: nextRoom.lensFacing, zoomLevel: nextRoom.zoomLevel, flashMode: nextRoom.flashMode)
                    camera.applyExposureIndex(nextRoom.exposureIndex)
                } else {
                    services.webRtcSession.applyCameraControls(
                        lensFacing: nextRoom.lensFacing,
                        zoomLevel: nextRoom.zoomLevel,
                        flashMode: nextRoom.flashMode
                    )
                    applyExposureIfNeeded(nextRoom.exposureIndex)
                }
                syncAspectRatioModeFromRoom(nextRoom.aspectRatioMode)
                syncToolbarExpandedFromRoom(nextRoom.toolbarExpanded)
                exposureValue = Double(nextRoom.exposureIndex) / 8.0
                prewarmHostStreamIfNeeded(for: nextRoom)
                handleFocusRequest(nextRoom)
                handleCaptureRequest(nextRoom.captureRequest)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func switchHostLens() {
        hostPreviewSwitchTask?.cancel()
        hostPreviewSwitching = true
        camera.switchLens()
        publishCurrentControls()
        hostPreviewSwitchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            hostPreviewLensFacing = services.webRtcSession.capturedLensFacing
            hostPreviewSwitching = false
            hostPreviewLensTarget = nil
            hostPreviewSwitchTask = nil
        }
    }

    private func performHostCapture() {
        if (room?.cameraMode ?? "photo") == "video" {
            if services.webRtcSession.isHostVideoRecording {
                services.webRtcSession.stopHostVideoRecording()
            } else {
                services.webRtcSession.startHostVideoRecording { url, error in
                    Task { await camera.saveCapturedVideoFromStream(url, error: error) }
                }
            }
            return
        }

        if services.webRtcSession.state != .idle {
            services.webRtcSession.captureHostPhoto(aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode), wantsPortraitMatte: false) { image, data, capturedDeviceOrientation, lensFacing, useLandscapeCanvas, _ in
                Task {
                    await camera.saveCapturedPhotoFromStream(
                        image,
                        data: data,
                        capturedDeviceOrientation: capturedDeviceOrientation,
                        lensFacing: lensFacing,
                        useLandscapeCanvas: useLandscapeCanvas,
                        aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode),
                        saveToPhotoLibrary: false
                    )
                }
            }
        } else {
            camera.capturePhoto(aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode)) { _ in }
        }
    }

    private func scheduleHostPreviewLensFacing(_ lensFacing: LensFacing) {
        guard hostPreviewLensTarget != lensFacing else { return }
        hostPreviewLensTarget = lensFacing
        hostPreviewLensTask?.cancel()
        hostPreviewLensFacing = lensFacing
        if hostPreviewSwitchTask == nil {
            hostPreviewSwitching = false
            hostPreviewLensTarget = nil
        }
    }

    private func handleCaptureRequest(_ request: CaptureRequest?) {
        guard let request, request.id != lastHandledCaptureRequestId else { return }
        lastHandledCaptureRequestId = request.id
        guard !isHandlingRemoteCapture else {
            resetCaptureRequest()
            return
        }
        isHandlingRemoteCapture = true

        Task {
            switch request.type {
            case "video_start":
                services.webRtcSession.startHostVideoRecording { url, error in
                    Task { await camera.saveCapturedVideoFromStream(url, error: error) }
                }
                resetCaptureRequest()
                isHandlingRemoteCapture = false
            case "video_pause":
                services.webRtcSession.pauseHostVideoRecording()
                resetCaptureRequest()
                isHandlingRemoteCapture = false
            case "video_resume":
                services.webRtcSession.resumeHostVideoRecording()
                resetCaptureRequest()
                isHandlingRemoteCapture = false
            case "video_stop":
                services.webRtcSession.stopHostVideoRecording()
                resetCaptureRequest()
                isHandlingRemoteCapture = false
            default:
                resetCaptureRequest()
                if services.webRtcSession.state != .idle {
                    services.webRtcSession.captureHostPhoto(aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode), wantsPortraitMatte: false) { image, data, capturedDeviceOrientation, lensFacing, useLandscapeCanvas, _ in
                        isHandlingRemoteCapture = false
                        Task {
                            await camera.saveCapturedPhotoFromStream(
                                image,
                                data: data,
                                capturedDeviceOrientation: capturedDeviceOrientation,
                                lensFacing: lensFacing,
                                useLandscapeCanvas: useLandscapeCanvas,
                                aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode),
                                saveToPhotoLibrary: false
                            )
                        }
                    }
                } else {
                    camera.capturePhoto(aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode)) { _ in
                        isHandlingRemoteCapture = false
                    }
                }
            }
        }
    }

    private func resetCaptureRequest() {
        Task { try? await services.roomRepository.resetCaptureRequest(roomCode: roomCode) }
    }

    private func handleFocusRequest(_ room: RoomDocument) {
        guard room.focusRequestId != 0, room.focusRequestId != lastHandledFocusRequestId else { return }
        lastHandledFocusRequestId = room.focusRequestId
        let point = CGPoint(x: room.focusPointX, y: room.focusPointY)
        focusReticlePoint = point
        services.webRtcSession.applyFocusPoint(x: point.x, y: point.y, lockEnabled: room.focusLockEnabled)
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            if focusReticlePoint == point {
                focusReticlePoint = nil
            }
        }
    }

    private func applyExposureIfNeeded(_ exposureIndex: Int) {
        guard lastAppliedExposureIndex != exposureIndex else { return }
        lastAppliedExposureIndex = exposureIndex
        services.webRtcSession.applyExposureIndex(exposureIndex)
    }

    private func prewarmHostStreamIfNeeded(for room: RoomDocument) {
        guard room.requestReceived, !room.controllerApproved else { return }
        guard services.webRtcSession.state == .idle, !isPrewarmingHostStream else { return }
        isPrewarmingHostStream = true
        Task {
            await camera.stopAndWait()
            await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomRepository)
            isPrewarmingHostStream = false
        }
    }

    private func updateApproval(approved: Bool) {
        if var currentRoom = room {
            currentRoom.controllerApproved = approved
            currentRoom.status = approved ? .connected : .denied
            room = currentRoom
        }

        Task {
            do {
                if approved {
                    try await services.roomRepository.approveController(roomCode: roomCode)
                    if services.webRtcSession.state == .idle {
                        await camera.stopAndWait()
                        await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomRepository)
                    }
                } else {
                    try await services.roomRepository.denyController(roomCode: roomCode)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func endSession() {
        Task {
            do {
                try await services.roomRepository.endSession(roomCode: roomCode)
                await returnToStart()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func returnToStart() async {
        await services.webRtcSession.finishHostVideoRecordingBeforeTeardown()
        services.webRtcSession.stop()
        camera.stop()
        path = NavigationPath()
    }

    private func publishCurrentControls() {
        Task {
            try? await services.roomRepository.updateControls(roomCode: roomCode, lensFacing: camera.lensFacing, zoomLevel: camera.zoomLevel, flashMode: camera.flashMode)
        }
    }

    private func updateGridEnabled(_ enabled: Bool) {
        Task { try? await services.roomRepository.updateGridEnabled(roomCode: roomCode, gridEnabled: enabled) }
    }

    private func updateSceneDetectionEnabled(_ enabled: Bool) {
        Task { try? await services.roomRepository.updateSceneDetectionEnabled(roomCode: roomCode, sceneDetectionEnabled: enabled) }
    }

    private func updateCameraMode(_ mode: String) {
        Task { try? await services.roomRepository.updateCameraMode(roomCode: roomCode, cameraMode: mode) }
    }

    private func updateFlashMode(_ mode: String) {
        Task { try? await services.roomRepository.updateFlashMode(roomCode: roomCode, flashMode: mode) }
    }

    private func updateNightModeEnabled(_ enabled: Bool) {
        Task { try? await services.roomRepository.updateNightModeEnabled(roomCode: roomCode, nightModeEnabled: enabled) }
    }

    private func updateVideoHdrEnabled(_ enabled: Bool) {
        Task { try? await services.roomRepository.updateVideoHdrEnabled(roomCode: roomCode, videoHdrEnabled: enabled) }
    }

    private func updateToolbarExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isHostToolRailExpanded = expanded
        }
        Task { try? await services.roomRepository.updateToolbarExpanded(roomCode: roomCode, toolbarExpanded: expanded) }
    }

    private func syncToolbarExpandedFromRoom(_ expanded: Bool) {
        guard isHostToolRailExpanded != expanded else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isHostToolRailExpanded = expanded
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
            }
        }
    }
}

struct CameraSwitchingOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .opacity(0.42)
            Rectangle()
                .fill(Color.black.opacity(0.18))
        }
        .allowsHitTesting(false)
    }
}
private struct HostRoomStatusCard: View {
    let roomCode: String
    let statusText: String

    private var spacedRoomCode: String {
        roomCode.map(String.init).joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(spacedRoomCode)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

        }
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

private struct HostApprovalActionButton: View {
    enum Style {
        case allow
        case deny

        var foreground: Color {
            switch self {
            case .allow: return .white
            case .deny: return .white
            }
        }

        var background: LinearGradient {
            switch self {
            case .allow:
                return LinearGradient(
                    colors: [Color(red: 0.70, green: 0.42, blue: 1.0), Color(red: 0.34, green: 0.08, blue: 1.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            case .deny:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.22, blue: 0.30).opacity(0.88), Color(red: 0.62, green: 0.06, blue: 0.13).opacity(0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    let title: String
    let systemName: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .black))
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(style.foreground)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(style.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(style == .allow ? 0.20 : 0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct HostTopStatusPill: View {
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

private struct HostRecordingPill: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isPaused ? Color.yellow : Color.red)
                .frame(width: 8, height: 8)
            Text(isPaused ? "PAUSED" : "REC")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }
}

private struct HostInfoChip: View {
    let text: String
    let systemName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.46), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct HostWarningChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.76))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.52), in: Capsule())
    }
}

private struct HostEndButton: View {
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

private struct HostRailButton: View {
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
