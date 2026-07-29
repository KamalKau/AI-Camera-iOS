import Foundation

protocol RoomCreating: Sendable {
    func createRoom() async throws -> RoomDocument
}

protocol RoomReading: Sendable {
    func room(roomCode: String) async throws -> RoomDocument?
    func observeRoom(roomCode: String) async -> AsyncThrowingStream<RoomDocument, Error>
}

protocol RoomConnectionManaging: Sendable {
    func requestConnection(roomCode: String) async throws
    func approveController(roomCode: String) async throws
    func denyController(roomCode: String) async throws
    func endSession(roomCode: String) async throws
}

protocol RoomBasicCameraControlUpdating: Sendable {
    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async throws
    func updateLensFacing(roomCode: String, lensFacing: LensFacing) async throws
    func updateZoomLevel(roomCode: String, zoomLevel: Double) async throws
    func updateZoomRange(roomCode: String, minZoom: Double, maxZoom: Double) async throws
    func updateFlashMode(roomCode: String, flashMode: String) async throws
    func updateCameraMode(roomCode: String, cameraMode: String) async throws
    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws
    func updateNightModeEnabled(roomCode: String, nightModeEnabled: Bool) async throws
    func updateVideoHdrEnabled(roomCode: String, videoHdrEnabled: Bool) async throws
    func updateToolbarExpanded(roomCode: String, toolbarExpanded: Bool) async throws
    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws
    func updateFlashSupported(roomCode: String, flashSupported: Bool) async throws
}

protocol RoomPortraitStateUpdating: Sendable {
    func updatePortraitControls(roomCode: String, blurLevel: String, strength: Int, effect: String) async throws
    func updatePortraitSubjectState(roomCode: String, state: PortraitSubjectState) async throws
    func updateFaceDetectionOverlay(roomCode: String, state: FaceDetectionOverlayState) async throws
}

protocol RoomSceneStateUpdating: Sendable {
    func updateSceneDetectionEnabled(roomCode: String, sceneDetectionEnabled: Bool) async throws
    func updateSceneDetectionState(roomCode: String, state: SceneDetectionState) async throws
}

protocol RoomFocusExposureUpdating: Sendable {
    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int64, lockEnabled: Bool) async throws
    func updateExposureState(roomCode: String, state: ExposureState) async throws
    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws
}

protocol RoomPreviewMetadataUpdating: Sendable {
    func updatePreviewSize(roomCode: String, width: Int, height: Int) async throws
}

protocol RoomCameraControlUpdating: RoomBasicCameraControlUpdating, RoomPortraitStateUpdating, RoomSceneStateUpdating, RoomFocusExposureUpdating, RoomPreviewMetadataUpdating {}

protocol RoomCaptureRequesting: Sendable {
    func requestCapture(roomCode: String, type: String) async throws
    func resetCaptureRequest(roomCode: String) async throws
}

protocol RoomSignaling: Sendable {
    func setOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws
    func setAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws
    func addCameraCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws
    func addControllerCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws
    func clearIceCandidates(roomCode: String) async throws
    func cameraCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload]
    func controllerCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload]
}

protocol RoomSignalingRepository: RoomReading, RoomSignaling {}

protocol RoomRepository: RoomCreating, RoomConnectionManaging, RoomCameraControlUpdating, RoomCaptureRequesting, RoomSignalingRepository {}
