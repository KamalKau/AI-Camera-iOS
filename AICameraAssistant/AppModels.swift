import Foundation

enum AppRoute: Hashable {
    case cameraHost(roomCode: String)
    case controllerEntry
    case waitingForApproval(roomCode: String)
}

enum LensFacing: String, CaseIterable, Codable, Sendable {
    case back
    case front
}

enum RoomStatus: String, Codable, Sendable {
    case created = "waiting"
    case waitingForApproval = "request_received"
    case connected
    case denied
    case disconnected
    case ended
}

enum StreamQualityMode: String, Codable, Sendable {
    case lowLatency = "low_latency"
    case balanced
    case quality
}

struct CaptureRequest: Codable, Equatable, Sendable {
    var id: String
    var type: String
    var requestedAt: Date

    nonisolated static func new(type: String = "photo") -> CaptureRequest {
        CaptureRequest(id: UUID().uuidString, type: type, requestedAt: Date())
    }
}

struct IceCandidatePayload: Codable, Equatable, Sendable, Identifiable {
    var id: String { candidate + sdpMid + String(sdpMLineIndex) }
    var candidate: String
    var sdpMid: String
    var sdpMLineIndex: Int32
}

struct RoomDocument: Codable, Equatable, Sendable {
    var roomCode: String
    var status: RoomStatus
    var requestReceived: Bool
    var controllerApproved: Bool
    var captureRequest: CaptureRequest?
    var lensFacing: LensFacing
    var zoomLevel: Double
    var minZoom: Double
    var maxZoom: Double
    var flashEnabled: Bool
    var flashMode: String
    var flashSupported: Bool
    var cameraMode: String
    var aspectRatioMode: String
    var gridEnabled: Bool
    var nightModeEnabled: Bool
    var videoHdrSupported: Bool
    var videoHdrEnabled: Bool
    var toolbarExpanded: Bool
    var focusRequestId: Int
    var focusPointX: Double
    var focusPointY: Double
    var focusLockEnabled: Bool
    var exposureMinIndex: Int
    var exposureMaxIndex: Int
    var exposureIndex: Int
    var streamQualityMode: StreamQualityMode
    var rtcSessionId: String?
    var sessionVersion: Int
    var previewWidth: Int
    var previewHeight: Int
    var offer: String?
    var answer: String?
    var cameraCandidates: [IceCandidatePayload]
    var controllerCandidates: [IceCandidatePayload]
    var updatedAt: Date

    nonisolated static func initial(roomCode: String) -> RoomDocument {
        RoomDocument(
            roomCode: roomCode,
            status: .created,
            requestReceived: false,
            controllerApproved: false,
            captureRequest: nil,
            lensFacing: .back,
            zoomLevel: 1.0,
            minZoom: 1.0,
            maxZoom: 8.0,
            flashEnabled: false,
            flashMode: "off",
            flashSupported: true,
            cameraMode: "photo",
            aspectRatioMode: "full",
            gridEnabled: false,
            nightModeEnabled: false,
            videoHdrSupported: false,
            videoHdrEnabled: false,
            toolbarExpanded: false,
            focusRequestId: 0,
            focusPointX: 0.5,
            focusPointY: 0.5,
            focusLockEnabled: false,
            exposureMinIndex: 0,
            exposureMaxIndex: 0,
            exposureIndex: 0,
            streamQualityMode: .lowLatency,
            rtcSessionId: nil,
            sessionVersion: Int(Date().timeIntervalSince1970 * 1000),
            previewWidth: 0,
            previewHeight: 0,
            offer: nil,
            answer: nil,
            cameraCandidates: [],
            controllerCandidates: [],
            updatedAt: Date()
        )
    }
}

extension String {
    nonisolated var normalizedRoomCode: String {
        trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

protocol RoomRepository: Sendable {
    func createRoom() async throws -> RoomDocument
    func room(roomCode: String) async throws -> RoomDocument?
    func observeRoom(roomCode: String) async -> AsyncThrowingStream<RoomDocument, Error>
    func requestConnection(roomCode: String) async throws
    func approveController(roomCode: String) async throws
    func denyController(roomCode: String) async throws
    func endSession(roomCode: String) async throws
    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) async throws
    func updateCameraMode(roomCode: String, cameraMode: String) async throws
    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws
    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws
    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int, lockEnabled: Bool) async throws
    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws
    func requestCapture(roomCode: String, type: String) async throws
    func resetCaptureRequest(roomCode: String) async throws
    func setOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws
    func setAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws
    func addCameraCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws
    func addControllerCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws
    func cameraCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload]
    func controllerCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload]
}

enum RoomRepositoryError: LocalizedError {
    case roomNotFound

    var errorDescription: String? { "Room not found." }
}
