import SwiftUI
import UIKit
import Vision

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
    @State private var hostFaceDetectionTask: Task<Void, Never>?
    @State private var isFaceDetectionAcquired = false
    @State private var isHostToolRailExpanded = false
    @State private var isHostBoomerangArmed = false
    @State private var isHostBoomerangCaptureAnimating = false
    @State private var hostBoomerangCaptureProgress = 0.0
    @State private var hostBoomerangProgressTask: Task<Void, Never>?
    @State private var boomerangStatusMessage: String?
    @State private var hostBurstCaptureTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                hostPreview

                boomerangHostOverlay
                    .zIndex(18)

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
            hostFaceDetectionTask?.cancel()
            hostBoomerangProgressTask?.cancel()
            hostBurstCaptureTask?.cancel()
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
                if let room {
                    HostFaceOverlay(
                        state: room.faceDetectionOverlayState,
                        sourceWidth: room.previewWidth,
                        sourceHeight: room.previewHeight,
                        isMirrored: false
                    )
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

    @ViewBuilder
    private var boomerangHostOverlay: some View {
        switch camera.boomerangCaptureManager.state {
        case .capturing:
            EmptyView()

        case .processing:
            EmptyView()

        case .previewing:
            BoomerangPreviewScreen(
                manager: camera.boomerangCaptureManager,
                onRetake: {
                    boomerangStatusMessage = nil
                    camera.boomerangCaptureManager.retake()
                }
            )

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Retake") {
                    camera.boomerangCaptureManager.retake()
                }
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Color.white, in: Capsule())
            }
            .padding(18)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 28)

        case .idle:
            EmptyView()
        }
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
                HostRailButton(systemName: "infinity", label: "Boom", isSelected: isHostBoomerangArmed) {
                    armHostBoomerangShutter()
                }
                .disabled(camera.boomerangCaptureManager.isBusy || services.webRtcSession.isHostVideoRecording)

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

            if let boomerangSaveMessage = camera.boomerangCaptureManager.saveMessage {
                HostInfoChip(text: boomerangSaveMessage, systemName: "infinity")
                    .multilineTextAlignment(.center)
            } else if let boomerangStatusMessage {
                HostInfoChip(text: boomerangStatusMessage, systemName: "infinity")
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
            hostModeButton("photo", label: "PHOTO")
            hostModeButton("video", label: "VIDEO")
            hostModeButton("portrait", label: "PORTRAIT")
        }
        .padding(4)
        .background(Color.black.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var hostCaptureControls: some View {
        VStack(spacing: 10) {
            hostShutterButton

            ZStack {
                hostModeStrip
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    Spacer(minLength: 0)
                    hostFlipCameraButton
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(.bottom, 10)
        .offset(y: 8)
    }

    private var hostShutterButton: some View {
        Button { performHostCapture() } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(hostShutterRingColor.opacity(0.96), lineWidth: 5)
                        .frame(width: 86, height: 86)

                    if isHostBoomerangCaptureAnimating || camera.boomerangCaptureManager.state == .capturing {
                        Circle()
                            .trim(from: 0, to: max(hostBoomerangCaptureProgress, camera.boomerangCaptureManager.progress))
                            .stroke(.yellow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 86, height: 86)
                            .rotationEffect(.degrees(-90))
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 12, height: 12)
                    } else if isHostBoomerangArmed {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 64, height: 64)
                        Image(systemName: "infinity")
                            .font(.system(size: 25, weight: .black))
                            .foregroundStyle(.black)
                    } else if (room?.cameraMode ?? "photo") == "video" {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 64, height: 64)
                    } else {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 64, height: 64)
                    }
                }
                .animation(.easeOut(duration: 0.16), value: isHostBoomerangArmed)
                .animation(.easeOut(duration: 0.16), value: camera.boomerangCaptureManager.progress)
                .animation(.linear(duration: 0.08), value: hostBoomerangCaptureProgress)

                Text(hostShutterLabel)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(hostShutterRingColor)
                    .frame(height: 13)
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.boomerangCaptureManager.isBusy || (services.webRtcSession.isHostVideoRecording && isHostBoomerangArmed))
        .accessibilityLabel(hostShutterLabel)
    }

    private var hostShutterRingColor: Color {
        if isHostBoomerangCaptureAnimating { return .yellow }
        if case .capturing = camera.boomerangCaptureManager.state { return .yellow }
        if isHostBoomerangArmed { return .yellow }
        if (room?.cameraMode ?? "photo") == "video" || services.webRtcSession.isHostVideoRecording { return .red }
        if (room?.cameraMode ?? "photo") == "portrait" { return Color(red: 0.78, green: 0.62, blue: 1.0) }
        return .white.opacity(0.96)
    }

    private var hostShutterLabel: String {
        if isHostBoomerangCaptureAnimating { return "BOOM" }
        if case .capturing = camera.boomerangCaptureManager.state { return "BOOM" }
        if isHostBoomerangArmed { return "BOOM \(BoomerangCaptureDefaults.durationLabel)" }
        if (room?.cameraMode ?? "photo") == "video" { return services.webRtcSession.isHostVideoRecording ? "STOP" : "VIDEO" }
        if (room?.cameraMode ?? "photo") == "portrait" { return "PORTRAIT" }
        return "PHOTO"
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
            for try await nextRoom in await services.roomReader.observeRoom(roomCode: roomCode) {
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
                let appliedZoomLevel: Double
                if services.webRtcSession.state == .idle {
                    camera.apply(lensFacing: nextRoom.lensFacing, zoomLevel: nextRoom.zoomLevel, flashMode: nextRoom.flashMode)
                    camera.applyExposureIndex(nextRoom.exposureIndex)
                    appliedZoomLevel = camera.zoomLevel
                } else {
                    appliedZoomLevel = services.webRtcSession.applyCameraControls(
                        lensFacing: nextRoom.lensFacing,
                        zoomLevel: nextRoom.zoomLevel,
                        flashMode: nextRoom.flashMode
                    )
                    applyExposureIfNeeded(nextRoom.exposureIndex)
                }
                publishCorrectedZoomIfNeeded(appliedZoomLevel, requestedZoomLevel: nextRoom.zoomLevel)
                syncAspectRatioModeFromRoom(nextRoom.aspectRatioMode)
                syncToolbarExpandedFromRoom(nextRoom.toolbarExpanded)
                exposureValue = Double(nextRoom.exposureIndex) / 8.0
                prewarmHostStreamIfNeeded(for: nextRoom)
                updateFaceDetectionPublishing(for: nextRoom)
                handleFocusRequest(nextRoom)
                handleCaptureRequest(nextRoom.captureRequest)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func switchHostLens() {
        guard !camera.boomerangCaptureManager.isBusy else { return }
        isHostBoomerangArmed = false
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
        if isHostBoomerangArmed {
            isHostBoomerangArmed = false
            Task {
                guard await startHostBoomerangCapture() else { return }
                await waitForBoomerangToFinishCaptureRequest()
                await restartHostPreviewAfterBoomerang()
            }
            return
        }

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

    private func armHostBoomerangShutter() {
        guard !camera.boomerangCaptureManager.isBusy, !services.webRtcSession.isHostVideoRecording else { return }
        isHostBoomerangArmed.toggle()
        boomerangStatusMessage = isHostBoomerangArmed ? "Boomerang ready" : nil
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
        if hostBurstCaptureTask != nil, request.type != "burst_stop" {
            resetCaptureRequest()
            return
        }
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
            case "boomerang":
                await handleBoomerangCapture()
            case "burst_start":
                resetCaptureRequest()
                startHostBurstCaptureIfPossible()
                isHandlingRemoteCapture = false
            case "burst_stop":
                resetCaptureRequest()
                stopHostBurstCapture()
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

    private func startHostBurstCaptureIfPossible() {
        guard hostBurstCaptureTask == nil else { return }
        guard !services.webRtcSession.isHostVideoRecording else { return }
        let maximumBurstCaptureCount = 100
        hostBurstCaptureTask = Task { @MainActor in
            defer {
                hostBurstCaptureTask = nil
            }

            for _ in 0..<maximumBurstCaptureCount {
                guard !Task.isCancelled else { return }
                await captureSingleHostBurstPhoto()
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
    }

    private func stopHostBurstCapture() {
        hostBurstCaptureTask?.cancel()
        hostBurstCaptureTask = nil
    }

    private func captureSingleHostBurstPhoto() async {
        if services.webRtcSession.state != .idle {
            await withCheckedContinuation { continuation in
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
                    continuation.resume()
                }
            }
        } else {
            await withCheckedContinuation { continuation in
                camera.capturePhoto(aspectRatio: CameraAspectRatio(roomValue: aspectRatioMode)) { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func handleBoomerangCapture() async {
        resetCaptureRequest()
        guard await startHostBoomerangCapture() else {
            isHandlingRemoteCapture = false
            return
        }
        await waitForBoomerangToFinishCaptureRequest()
        await restartHostPreviewAfterBoomerang()
        isHandlingRemoteCapture = false
    }

    private func startHostBoomerangCapture() async -> Bool {
        guard !camera.boomerangCaptureManager.isBusy else { return false }
        guard !services.webRtcSession.isHostVideoRecording else { return false }
        boomerangStatusMessage = nil
        startHostBoomerangShutterProgress()
        services.webRtcSession.stop()
        let started = await camera.prepareForBoomerangCapture(
            lensFacing: room?.lensFacing ?? camera.lensFacing,
            zoomLevel: room?.zoomLevel ?? camera.zoomLevel,
            flashMode: room?.flashMode ?? camera.flashMode
        )
        guard started else {
            stopHostBoomerangShutterProgress()
            boomerangStatusMessage = "Boomerang failed: camera did not start."
            return false
        }
        try? await Task.sleep(for: .milliseconds(500))
        camera.startBoomerangCapture()
        return true
    }

    private func waitForBoomerangToFinishCaptureRequest() async {
        let startDeadline = Date().addingTimeInterval(2.0)
        while !camera.boomerangCaptureManager.isBusy, Date() < startDeadline {
            if case .failed = camera.boomerangCaptureManager.state { return }
            try? await Task.sleep(for: .milliseconds(60))
        }

        while camera.boomerangCaptureManager.isBusy {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func restartHostPreviewAfterBoomerang() async {
        guard room?.status == .connected else { return }
        await camera.stopAndWait()
        await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomSignalingRepository)
    }

    private func startHostBoomerangShutterProgress() {
        hostBoomerangProgressTask?.cancel()
        isHostBoomerangCaptureAnimating = true
        hostBoomerangCaptureProgress = 0

        hostBoomerangProgressTask = Task { @MainActor in
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(BoomerangCaptureDefaults.captureDurationMilliseconds / steps))
                guard !Task.isCancelled else { return }
                hostBoomerangCaptureProgress = Double(step) / Double(steps)
            }
            stopHostBoomerangShutterProgress()
        }
    }

    private func stopHostBoomerangShutterProgress() {
        hostBoomerangProgressTask?.cancel()
        hostBoomerangProgressTask = nil
        isHostBoomerangCaptureAnimating = false
        hostBoomerangCaptureProgress = 0
    }

    private func resetCaptureRequest() {
        Task { try? await services.roomCaptureRequester.resetCaptureRequest(roomCode: roomCode) }
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
            await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomSignalingRepository)
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
                    try await services.roomConnectionManager.approveController(roomCode: roomCode)
                    if services.webRtcSession.state == .idle {
                        await camera.stopAndWait()
                        await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomSignalingRepository)
                    }
                } else {
                    try await services.roomConnectionManager.denyController(roomCode: roomCode)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func endSession() {
        Task {
            do {
                try await services.roomConnectionManager.endSession(roomCode: roomCode)
                await returnToStart()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func returnToStart() async {
        await services.webRtcSession.finishHostVideoRecordingBeforeTeardown()
        hostFaceDetectionTask?.cancel()
        hostFaceDetectionTask = nil
        isFaceDetectionAcquired = false
        services.webRtcSession.stop()
        camera.stop()
        path = NavigationPath()
    }

    private func publishCurrentControls() {
        Task {
            try? await services.roomCameraControlUpdater.updateControls(roomCode: roomCode, lensFacing: camera.lensFacing, zoomLevel: camera.zoomLevel, flashMode: camera.flashMode)
        }
    }

    private func publishCorrectedZoomIfNeeded(_ appliedZoomLevel: Double, requestedZoomLevel: Double) {
        guard abs(appliedZoomLevel - requestedZoomLevel) > 0.001 else { return }
        Task {
            try? await services.roomCameraControlUpdater.updateZoomLevel(roomCode: roomCode, zoomLevel: appliedZoomLevel)
        }
    }

    private func updateFaceDetectionPublishing(for room: RoomDocument) {
        let shouldPublish = room.controllerApproved && services.webRtcSession.state != .idle && services.webRtcSession.localVideoTrack != nil
        guard shouldPublish else {
            hostFaceDetectionTask?.cancel()
            hostFaceDetectionTask = nil
            clearPublishedFaceDetectionState()
            return
        }
        guard hostFaceDetectionTask == nil else { return }

        hostFaceDetectionTask = Task { @MainActor in
            while !Task.isCancelled {
                await publishFaceDetectionState()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func publishFaceDetectionState() async {
        guard let image = await captureHostPreviewSnapshot() else {
            clearPublishedFaceDetectionState()
            return
        }
        let boxes = await Self.detectFaceBounds(in: image)
        guard !boxes.isEmpty else {
            isFaceDetectionAcquired = false
            clearPublishedFaceDetectionState()
            return
        }
        guard !isFaceDetectionAcquired else { return }
        isFaceDetectionAcquired = true

        let primaryBox = boxes.first ?? .zero
        let timestamp = RoomSchema.timestampId()
        let overlayState = FaceDetectionOverlayState(
            detected: true,
            count: boxes.count,
            timestamp: timestamp,
            primaryBox: primaryBox,
            boxes: boxes
        )
        try? await services.roomCameraControlUpdater.updateFaceDetectionOverlay(roomCode: roomCode, state: overlayState)

        let portraitState = PortraitSubjectState(
            status: "Subject locked",
            faceBounds: primaryBox
        )
        try? await services.roomCameraControlUpdater.updatePortraitSubjectState(roomCode: roomCode, state: portraitState)
    }

    private func clearPublishedFaceDetectionState() {
        isFaceDetectionAcquired = false
        Task {
            try? await services.roomCameraControlUpdater.updateFaceDetectionOverlay(roomCode: roomCode, state: .empty)
            try? await services.roomCameraControlUpdater.updatePortraitSubjectState(roomCode: roomCode, state: .finding)
        }
    }

    private func captureHostPreviewSnapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            services.webRtcSession.captureHostPhoto(aspectRatio: .full, wantsPortraitMatte: false) { image, _, _, _, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private nonisolated static func detectFaceBounds(in image: UIImage) async -> [NormalizedFaceBounds] {
        await Task.detached(priority: .utility) {
            guard let cgImage = image.cgImage else { return [] }
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                return (request.results ?? [])
                    .map { observation in
                        expandedFaceBounds(for: observation.boundingBox)
                    }
                    .filter(\.isValid)
            } catch {
                return []
            }
        }.value
    }

    private nonisolated static func expandedFaceBounds(for visionBox: CGRect) -> NormalizedFaceBounds {
        let width = Double(visionBox.width)
        let height = Double(visionBox.height)
        let horizontalPadding = width * 0.10
        let topPadding = height * 0.28
        let bottomPadding = height * 0.10

        return NormalizedFaceBounds(
            left: max(0.0, Double(visionBox.minX) - horizontalPadding),
            top: max(0.0, Double(1.0 - visionBox.maxY) - topPadding),
            right: min(1.0, Double(visionBox.maxX) + horizontalPadding),
            bottom: min(1.0, Double(1.0 - visionBox.minY) + bottomPadding)
        )
    }

    private func updateGridEnabled(_ enabled: Bool) {
        Task { try? await services.roomCameraControlUpdater.updateGridEnabled(roomCode: roomCode, gridEnabled: enabled) }
    }

    private func updateSceneDetectionEnabled(_ enabled: Bool) {
        Task { try? await services.roomCameraControlUpdater.updateSceneDetectionEnabled(roomCode: roomCode, sceneDetectionEnabled: enabled) }
    }

    private func updateCameraMode(_ mode: String) {
        isHostBoomerangArmed = false
        boomerangStatusMessage = nil
        Task { try? await services.roomCameraControlUpdater.updateCameraMode(roomCode: roomCode, cameraMode: mode) }
    }

    private func updateFlashMode(_ mode: String) {
        Task { try? await services.roomCameraControlUpdater.updateFlashMode(roomCode: roomCode, flashMode: mode) }
    }

    private func updateNightModeEnabled(_ enabled: Bool) {
        Task { try? await services.roomCameraControlUpdater.updateNightModeEnabled(roomCode: roomCode, nightModeEnabled: enabled) }
    }

    private func updateVideoHdrEnabled(_ enabled: Bool) {
        Task { try? await services.roomCameraControlUpdater.updateVideoHdrEnabled(roomCode: roomCode, videoHdrEnabled: enabled) }
    }

    private func updateToolbarExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isHostToolRailExpanded = expanded
        }
        Task { try? await services.roomCameraControlUpdater.updateToolbarExpanded(roomCode: roomCode, toolbarExpanded: expanded) }
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
                try await services.roomCameraControlUpdater.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: safeMode)
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

private struct HostFaceOverlay: View {
    let state: FaceDetectionOverlayState
    let sourceWidth: Int
    let sourceHeight: Int
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
                let videoDrawRect = videoDrawRect(in: geometry.size)
                let visibleBoxes = boxes(at: timeline.date)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(visibleBoxes.enumerated()), id: \.offset) { _, box in
                        let rect = displayRect(for: box, videoDrawRect: videoDrawRect, canvasSize: geometry.size)
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

    private func videoDrawRect(in canvasSize: CGSize) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let sourceAspect = CGFloat(sourceWidth > 0 && sourceHeight > 0 ? Double(sourceWidth) / Double(sourceHeight) : 16.0 / 9.0)
        let canvasAspect = canvasSize.width / max(canvasSize.height, 1)
        let size: CGSize
        if canvasAspect > sourceAspect {
            size = CGSize(width: canvasSize.width, height: canvasSize.width / sourceAspect)
        } else {
            size = CGSize(width: canvasSize.height * sourceAspect, height: canvasSize.height)
        }
        return CGRect(
            x: (canvasSize.width - size.width) / 2.0,
            y: (canvasSize.height - size.height) / 2.0,
            width: size.width,
            height: size.height
        )
    }

    private func displayRect(for box: NormalizedFaceBounds, videoDrawRect: CGRect, canvasSize: CGSize) -> CGRect {
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
