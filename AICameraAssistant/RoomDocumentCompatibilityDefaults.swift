import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

enum RoomDocumentCompatibilityDefaults {
    private static let expirationDurationMs: Int64 = 30 * 60 * 1000

    static func restFields(now: Int64) -> [String: FirestoreValue] {
        [
            "boomerangEnabled": .bool(false),
            "gestureCaptureEnabled": .bool(false),
            "smartFramingEnabled": .bool(false),
            "smartFramingGuidance": .string(""),
            "smartFramingTimestamp": .integer(0),
            "smartFramingSessionId": .string(""),
            "videoQuality": .string("FHD_30"),
            "supportedVideoQualities": .array([]),
            "videoRecordingState": .string("idle"),
            "videoRecordingUpdatedAt": .integer(0),
            "focusX": .null,
            "focusY": .null,
            "signalingGeneration": .integer(0),
            "answerGeneration": .integer(0),
            "offerCreatedAt": .integer(0),
            "answerCreatedAt": .integer(0),
            "commandId": .null,
            "commandType": .null,
            "commandSequence": .integer(0),
            "commandIssuedAt": .integer(0),
            "commandAckId": .null,
            "commandAckSequence": .integer(0),
            "createdAt": .integer(now),
            "lastActivityAt": .integer(now),
            "lastHeartbeatAt": .integer(now),
            "expiresAt": .integer(now + expirationDurationMs)
        ]
    }

    #if canImport(FirebaseFirestore)
    static func sdkFields(now: Int64) -> [String: Any] {
        [
            "boomerangEnabled": false,
            "gestureCaptureEnabled": false,
            "smartFramingEnabled": false,
            "smartFramingGuidance": "",
            "smartFramingTimestamp": 0,
            "smartFramingSessionId": "",
            "videoQuality": "FHD_30",
            "supportedVideoQualities": [],
            "videoRecordingState": "idle",
            "videoRecordingUpdatedAt": 0,
            "focusX": NSNull(),
            "focusY": NSNull(),
            "signalingGeneration": 0,
            "answerGeneration": 0,
            "offerCreatedAt": 0,
            "answerCreatedAt": 0,
            "commandId": NSNull(),
            "commandType": NSNull(),
            "commandSequence": 0,
            "commandIssuedAt": 0,
            "commandAckId": NSNull(),
            "commandAckSequence": 0,
            "createdAt": now,
            "lastActivityAt": now,
            "lastHeartbeatAt": now,
            "expiresAt": now + expirationDurationMs
        ]
    }
    #endif
}
