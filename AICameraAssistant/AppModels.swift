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
    var id: Int64
    var type: String
    var requestedAt: Date

    nonisolated static func new(type: String = "photo") -> CaptureRequest {
        CaptureRequest(id: Int64(Date().timeIntervalSince1970 * 1000), type: type, requestedAt: Date())
    }
}

struct NormalizedFaceBounds: Codable, Equatable, Sendable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    nonisolated static let zero = NormalizedFaceBounds(left: 0, top: 0, right: 0, bottom: 0)

    nonisolated var isValid: Bool {
        right > left && bottom > top
    }
}

struct CaptureRequestState: Codable, Equatable, Sendable {
    var isRequested: Bool
    var id: Int64
    var type: String

    nonisolated static let empty = CaptureRequestState(isRequested: false, id: 0, type: "photo")
}

struct FocusRequestState: Codable, Equatable, Sendable {
    var requestId: Int64
    var pointX: Double
    var pointY: Double
    var lockEnabled: Bool

    nonisolated static let centered = FocusRequestState(requestId: 0, pointX: 0.5, pointY: 0.5, lockEnabled: false)
}

struct ExposureState: Codable, Equatable, Sendable {
    var minIndex: Int
    var maxIndex: Int
    var currentIndex: Int

    nonisolated static let zero = ExposureState(minIndex: 0, maxIndex: 0, currentIndex: 0)
}

struct PortraitSubjectState: Codable, Equatable, Sendable {
    var status: String
    var faceBounds: NormalizedFaceBounds

    nonisolated static let finding = PortraitSubjectState(status: "finding", faceBounds: .zero)
}

struct FaceDetectionOverlayState: Codable, Equatable, Sendable {
    var detected: Bool
    var count: Int
    var timestamp: Int64
    var primaryBox: NormalizedFaceBounds
    var boxes: [NormalizedFaceBounds]

    nonisolated static let empty = FaceDetectionOverlayState(
        detected: false,
        count: 0,
        timestamp: 0,
        primaryBox: .zero,
        boxes: []
    )
}

struct SceneDetectionState: Codable, Equatable, Sendable {
    var key: String
    var label: String
    var suggestion: String
    var confidence: Double
    var timestamp: Int64
    var autoAdjustment: String

    nonisolated static let empty = SceneDetectionState(
        key: "auto",
        label: "",
        suggestion: "",
        confidence: 0,
        timestamp: 0,
        autoAdjustment: ""
    )
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
    var captureRequestId: Int64
    var captureRequestType: String
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
    var focusRequestId: Int64
    var focusPointX: Double
    var focusPointY: Double
    var focusLockEnabled: Bool
    var exposureMinIndex: Int
    var exposureMaxIndex: Int
    var exposureIndex: Int
    var streamQualityMode: StreamQualityMode
    var rtcSessionId: String?
    var sessionVersion: Int64
    var previewWidth: Int
    var previewHeight: Int
    var portraitBlurLevel: String
    var portraitStrength: Int
    var portraitEffect: String
    var portraitStatus: String
    var portraitFaceLeft: Double
    var portraitFaceTop: Double
    var portraitFaceRight: Double
    var portraitFaceBottom: Double
    var faceDetected: Bool
    var faceCount: Int
    var faceDetectionTimestamp: Int64
    var faceBox: NormalizedFaceBounds
    var faceBoxes: [NormalizedFaceBounds]
    var sceneDetectionEnabled: Bool
    var sceneDetection: SceneDetectionState
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
            captureRequestId: 0,
            captureRequestType: "photo",
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
            sessionVersion: Int64(Date().timeIntervalSince1970 * 1000),
            previewWidth: 0,
            previewHeight: 0,
            portraitBlurLevel: "blur",
            portraitStrength: 5,
            portraitEffect: "blur",
            portraitStatus: "finding",
            portraitFaceLeft: 0,
            portraitFaceTop: 0,
            portraitFaceRight: 0,
            portraitFaceBottom: 0,
            faceDetected: false,
            faceCount: 0,
            faceDetectionTimestamp: 0,
            faceBox: .zero,
            faceBoxes: [],
            sceneDetectionEnabled: false,
            sceneDetection: .empty,
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
    func updatePortraitControls(roomCode: String, blurLevel: String, strength: Int, effect: String) async throws
    func updatePortraitSubjectState(roomCode: String, state: PortraitSubjectState) async throws
    func updateFaceDetectionOverlay(roomCode: String, state: FaceDetectionOverlayState) async throws
    func updateSceneDetectionEnabled(roomCode: String, sceneDetectionEnabled: Bool) async throws
    func updateSceneDetectionState(roomCode: String, state: SceneDetectionState) async throws
    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws
    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int64, lockEnabled: Bool) async throws
    func updateExposureState(roomCode: String, state: ExposureState) async throws
    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws
    func updateFlashSupported(roomCode: String, flashSupported: Bool) async throws
    func updatePreviewSize(roomCode: String, width: Int, height: Int) async throws
    func requestCapture(roomCode: String, type: String) async throws
    func resetCaptureRequest(roomCode: String) async throws
    func setOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws
    func setAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws
    func addCameraCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws
    func addControllerCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws
    func clearIceCandidates(roomCode: String) async throws
    func cameraCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload]
    func controllerCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload]
}

extension RoomDocument {
    var captureRequestState: CaptureRequestState {
        CaptureRequestState(isRequested: captureRequest != nil, id: captureRequestId, type: captureRequestType)
    }

    var focusRequestState: FocusRequestState {
        FocusRequestState(requestId: focusRequestId, pointX: focusPointX, pointY: focusPointY, lockEnabled: focusLockEnabled)
    }

    var exposureState: ExposureState {
        ExposureState(minIndex: exposureMinIndex, maxIndex: exposureMaxIndex, currentIndex: exposureIndex)
    }

    var portraitSubjectState: PortraitSubjectState {
        PortraitSubjectState(status: portraitStatus, faceBounds: NormalizedFaceBounds(left: portraitFaceLeft, top: portraitFaceTop, right: portraitFaceRight, bottom: portraitFaceBottom))
    }

    var faceDetectionOverlayState: FaceDetectionOverlayState {
        FaceDetectionOverlayState(detected: faceDetected, count: faceCount, timestamp: faceDetectionTimestamp, primaryBox: faceBox, boxes: faceBoxes)
    }

    var portraitSubjectX: Double { portraitFaceLeft }
    var portraitSubjectY: Double { portraitFaceTop }
    var portraitSubjectWidth: Double { max(0, portraitFaceRight - portraitFaceLeft) }
    var portraitSubjectHeight: Double { max(0, portraitFaceBottom - portraitFaceTop) }
    var faceBoxLeft: Double { faceBox.left }
    var faceBoxTop: Double { faceBox.top }
    var faceBoxRight: Double { faceBox.right }
    var faceBoxBottom: Double { faceBox.bottom }
    var sceneKey: String { sceneDetection.key }
    var sceneLabel: String { sceneDetection.label }
    var sceneSuggestion: String { sceneDetection.suggestion }
    var sceneConfidence: Double { sceneDetection.confidence }
    var sceneTimestamp: Int64 { sceneDetection.timestamp }
    var sceneAutoAdjustment: String { sceneDetection.autoAdjustment }
}

extension RoomRepository {
    func sendConnectionRequest(roomCode: String) async throws {
        try await requestConnection(roomCode: roomCode)
    }

    func updateApproval(roomCode: String, approved: Bool) async throws {
        if approved {
            try await approveController(roomCode: roomCode)
        } else {
            try await denyController(roomCode: roomCode)
        }
    }

    func sendCaptureRequest(roomCode: String, type: String) async throws {
        try await requestCapture(roomCode: roomCode, type: type)
    }

    func saveOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try await setOffer(sdp, roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func saveAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try await setAnswer(sdp, roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func addCameraIceCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try await addCameraCandidate(candidate, roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func addControllerIceCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try await addControllerCandidate(candidate, roomCode: roomCode, rtcSessionId: rtcSessionId)
    }
}

enum RoomRepositoryError: LocalizedError {
    case roomNotFound

    var errorDescription: String? { "Room not found." }
}
