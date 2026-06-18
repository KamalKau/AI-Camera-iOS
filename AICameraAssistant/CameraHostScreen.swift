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
    @State private var isPrewarmingHostStream = false
    @State private var hostPreviewLensFacing: LensFacing = .back
    @State private var hostPreviewLensTask: Task<Void, Never>?
    @State private var hostPreviewLensTarget: LensFacing?
    @State private var hostPreviewSwitching = false
    @State private var hostPreviewSwitchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            hostPreview
            VStack {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            HStack {
                Spacer()
                hostToolRail
            }
            .padding(.trailing, 16)
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
            .aspectRatio((room?.aspectRatioMode ?? "full").cameraPreviewAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            CameraStatusPill(primary: "Room \(roomCode)", secondary: statusText)
            Spacer()
        }
    }

    private var hostToolRail: some View {
        VStack(spacing: 14) {
            CameraCircleButton(systemName: "arrow.triangle.2.circlepath.camera") {
                switchHostLens()
            }

            CameraCircleButton(
                systemName: camera.flashMode.cameraFlashIconName,
                isSelected: camera.flashMode != "off"
            ) {
                camera.flashMode = camera.flashMode.nextCameraFlashMode
                publishCurrentControls()
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

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if camera.permissionState == .denied {
                Text("Camera permission is required to host a room.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if room?.requestReceived == true, room?.controllerApproved == false {
                approvalPanel
            }

            HStack(spacing: 10) {
                Text(camera.lensFacing.rawValue.capitalized)
                Text((room?.cameraMode ?? "photo").capitalized)
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1fx", camera.zoomLevel))
                Text(camera.flashMode.cameraFlashLabel)
                Text((room?.aspectRatioMode ?? "full").cameraAspectRatioLabel)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.42), in: Capsule())

            if let hostInsightText {
                Text(hostInsightText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.42), in: Capsule())
            }

            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }

            if let photoSaveMessage = camera.photoSaveMessage {
                Text(photoSaveMessage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.42), in: Capsule())
            }
        }
    }

    private var approvalPanel: some View {
        HStack(spacing: 14) {
            CameraCircleButton(systemName: "xmark", role: .destructive) {
                updateApproval(approved: false)
            }
            VStack(spacing: 2) {
                Text("Controller requesting access")
                    .font(.caption.weight(.semibold))
                Text("Approve to start live preview")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            CameraCircleButton(systemName: "checkmark") {
                updateApproval(approved: true)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18), lineWidth: 1))
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

    private var hostInsightText: String? {
        guard let room else { return nil }
        if room.cameraMode == "portrait" {
            return "Portrait \(room.portraitEffect.replacingOccurrences(of: "_", with: " ").capitalized) \(room.portraitStrength)/7"
        }
        if room.sceneDetectionEnabled {
            let label = room.sceneLabel.isEmpty ? "Scene detection ready" : room.sceneLabel
            return room.sceneSuggestion.isEmpty ? label : "\(label): \(room.sceneSuggestion)"
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
            case "video_stop":
                services.webRtcSession.stopHostVideoRecording()
                resetCaptureRequest()
                isHandlingRemoteCapture = false
            default:
                resetCaptureRequest()
                if services.webRtcSession.state != .idle {
                    services.webRtcSession.captureHostPhoto(wantsPortraitMatte: false) { image, data, capturedDeviceOrientation, lensFacing, useLandscapeCanvas, _ in
                        isHandlingRemoteCapture = false
                        Task {
                            await camera.saveCapturedPhotoFromStream(
                                image,
                                data: data,
                                capturedDeviceOrientation: capturedDeviceOrientation,
                                lensFacing: lensFacing,
                                useLandscapeCanvas: useLandscapeCanvas,
                                saveToPhotoLibrary: false
                            )
                        }
                    }
                } else {
                    camera.capturePhoto { _ in
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
        Task {
            do {
                if approved {
                    if services.webRtcSession.state == .idle {
                        await camera.stopAndWait()
                        await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomRepository)
                    }
                    try await services.roomRepository.approveController(roomCode: roomCode)
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

    private func updateAspectRatioMode(_ mode: String) {
        Task { try? await services.roomRepository.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: mode) }
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
