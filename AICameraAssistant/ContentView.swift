@preconcurrency import AVFoundation
import Combine
import Photos
import SwiftUI
import UIKit
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
#if canImport(WebRTC)
import WebRTC
#endif

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
    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) async throws
    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws
    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws
    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int, lockEnabled: Bool) async throws
    func requestCapture(roomCode: String) async throws
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

actor LocalRoomRepository: RoomRepository {
    static let shared = LocalRoomRepository()

    private var rooms: [String: RoomDocument] = [:]
    private var continuations: [String: [UUID: AsyncThrowingStream<RoomDocument, Error>.Continuation]] = [:]

    func createRoom() async throws -> RoomDocument {
        var code = Self.makeRoomCode()
        while rooms[code] != nil { code = Self.makeRoomCode() }
        let room = RoomDocument.initial(roomCode: code)
        rooms[code] = room
        publish(room)
        return room
    }

    func room(roomCode: String) async throws -> RoomDocument? {
        rooms[roomCode.normalizedRoomCode]
    }

    func observeRoom(roomCode: String) async -> AsyncThrowingStream<RoomDocument, Error> {
        let normalizedCode = roomCode.normalizedRoomCode
        return AsyncThrowingStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, id: id, roomCode: normalizedCode) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id, roomCode: normalizedCode) }
            }
        }
    }

    func requestConnection(roomCode: String) async throws {
        try update(roomCode: roomCode) { room in
            room.requestReceived = true
            room.status = .waitingForApproval
            room.controllerApproved = false
            room.offer = nil
            room.answer = nil
            room.rtcSessionId = nil
            room.cameraCandidates = []
            room.controllerCandidates = []
        }
    }

    func approveController(roomCode: String) async throws {
        try update(roomCode: roomCode) { room in
            room.controllerApproved = true
            room.status = .connected
        }
    }

    func denyController(roomCode: String) async throws {
        try update(roomCode: roomCode) { room in
            room.controllerApproved = false
            room.status = .denied
        }
    }

    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) async throws {
        try update(roomCode: roomCode) { room in
            room.lensFacing = lensFacing
            room.zoomLevel = max(1.0, min(8.0, zoomLevel))
            room.flashEnabled = flashEnabled
            room.flashMode = flashEnabled ? "on" : "off"
        }
    }

    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws {
        try update(roomCode: roomCode) { $0.gridEnabled = gridEnabled }
    }

    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws {
        try update(roomCode: roomCode) { $0.aspectRatioMode = Self.safeAspectRatioMode(aspectRatioMode) }
    }

    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int, lockEnabled: Bool) async throws {
        try update(roomCode: roomCode) { room in
            room.focusPointX = min(1.0, max(0.0, x))
            room.focusPointY = min(1.0, max(0.0, y))
            room.focusRequestId = requestId
            room.focusLockEnabled = lockEnabled
        }
    }

    func requestCapture(roomCode: String) async throws {
        try update(roomCode: roomCode) { $0.captureRequest = .new() }
    }

    func setOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try update(roomCode: roomCode) {
            $0.offer = sdp
            $0.answer = nil
            $0.rtcSessionId = rtcSessionId
        }
    }

    func setAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try update(roomCode: roomCode) {
            $0.answer = sdp
            $0.rtcSessionId = rtcSessionId
        }
    }

    func addCameraCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try update(roomCode: roomCode) { $0.cameraCandidates.append(candidate) }
    }

    func addControllerCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try update(roomCode: roomCode) { $0.controllerCandidates.append(candidate) }
    }

    func cameraCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        rooms[roomCode.normalizedRoomCode]?.cameraCandidates ?? []
    }

    func controllerCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        rooms[roomCode.normalizedRoomCode]?.controllerCandidates ?? []
    }

    private func register(
        _ continuation: AsyncThrowingStream<RoomDocument, Error>.Continuation,
        id: UUID,
        roomCode: String
    ) {
        continuations[roomCode, default: [:]][id] = continuation
        if let room = rooms[roomCode] { continuation.yield(room) }
    }

    private func unregister(id: UUID, roomCode: String) {
        continuations[roomCode]?[id] = nil
    }

    private func update(roomCode: String, mutate: (inout RoomDocument) -> Void) throws {
        let normalizedCode = roomCode.normalizedRoomCode
        guard var room = rooms[normalizedCode] else { throw RoomRepositoryError.roomNotFound }
        mutate(&room)
        room.updatedAt = Date()
        rooms[normalizedCode] = room
        publish(room)
    }

    private func publish(_ room: RoomDocument) {
        continuations[room.roomCode]?.values.forEach { $0.yield(room) }
    }

    private nonisolated static func makeRoomCode() -> String {
        String(Int.random(in: 100_000...999_999))
    }

    private nonisolated static func safeAspectRatioMode(_ mode: String) -> String {
        ["full", "4:3", "square"].contains(mode) ? mode : "full"
    }
}

actor FirestoreRoomRepository: RoomRepository {
    private let collectionName = "rooms"
    private let configuration: FirestoreRESTConfiguration?

    init(configuration: FirestoreRESTConfiguration? = FirestoreRESTConfiguration.load()) {
        self.configuration = configuration
    }

    func createRoom() async throws -> RoomDocument {
        var code = Self.makeRoomCode()
        while try await room(roomCode: code) != nil { code = Self.makeRoomCode() }
        let room = RoomDocument.initial(roomCode: code)
        try await setRoom(room)
        return room
    }

    func room(roomCode: String) async throws -> RoomDocument? {
        let request = try makeRequest(roomCode: roomCode.normalizedRoomCode, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        if httpResponse.statusCode == 404 { return nil }
        try validate(httpResponse: httpResponse, data: data)
        let document = try JSONDecoder().decode(FirestoreDocument.self, from: data)
        return Self.decodeRoom(document.fields)
    }

    func observeRoom(roomCode: String) async -> AsyncThrowingStream<RoomDocument, Error> {
        let normalizedCode = roomCode.normalizedRoomCode
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastRoom: RoomDocument?
                var retryDelay: Duration = .seconds(1)
                while !Task.isCancelled {
                    do {
                        if let nextRoom = try await self.room(roomCode: normalizedCode), nextRoom != lastRoom {
                            lastRoom = nextRoom
                            continuation.yield(nextRoom)
                        }
                        retryDelay = .seconds(1)
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        if Self.isQuotaError(error) {
                            try? await Task.sleep(for: retryDelay)
                            retryDelay = min(retryDelay * 2, .seconds(16))
                        } else {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func requestConnection(roomCode: String) async throws {
        try await clearIceCandidates(roomCode: roomCode)
        try await update(roomCode: roomCode, values: [
            "requestReceived": true,
            "controllerApproved": false,
            "status": RoomStatus.waitingForApproval.rawValue,
            "offer": FirestoreValue.null,
            "answer": FirestoreValue.null,
            "rtcSessionId": FirestoreValue.null
        ])
    }

    func approveController(roomCode: String) async throws {
        try await update(roomCode: roomCode, values: [
            "requestReceived": false,
            "controllerApproved": true,
            "status": RoomStatus.connected.rawValue
        ])
    }

    func denyController(roomCode: String) async throws {
        try await update(roomCode: roomCode, values: ["controllerApproved": false, "status": RoomStatus.denied.rawValue])
    }

    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: [
            "lensFacing": lensFacing.rawValue,
            "zoomLevel": max(1.0, min(8.0, zoomLevel)),
            "flashEnabled": flashEnabled,
            "flashMode": flashEnabled ? "on" : "off"
        ])
    }

    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["gridEnabled": gridEnabled])
    }

    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws {
        try await update(roomCode: roomCode, values: ["aspectRatioMode": Self.safeAspectRatioMode(aspectRatioMode)])
    }

    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int, lockEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: [
            "focusPointX": min(1.0, max(0.0, x)),
            "focusPointY": min(1.0, max(0.0, y)),
            "focusRequestId": requestId,
            "focusLockEnabled": lockEnabled
        ])
    }

    func requestCapture(roomCode: String) async throws {
        let request = CaptureRequest.new()
        try await update(roomCode: roomCode, values: [
            "captureRequest": true,
            "captureRequestId": request.id,
            "captureRequestType": request.type
        ])
    }

    func setOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try await update(roomCode: roomCode, values: [
            "offer": sdp,
            "answer": FirestoreValue.null,
            "rtcSessionId": rtcSessionId
        ])
    }

    func setAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try await update(roomCode: roomCode, values: [
            "answer": sdp,
            "rtcSessionId": rtcSessionId
        ])
    }

    func addCameraCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try await addCandidate(candidate, collection: "iceCandidatesCamera", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func addControllerCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try await addCandidate(candidate, collection: "iceCandidatesController", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func cameraCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        try await candidates(collection: "iceCandidatesCamera", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func controllerCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        try await candidates(collection: "iceCandidatesController", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    private func update(roomCode: String, values: [String: Any]) async throws {
        var encodedValues = values.mapValues(Self.firestoreValue)
        encodedValues["updatedAt"] = .timestamp(Date())
        try await patch(roomCode: roomCode.normalizedRoomCode, fields: encodedValues)
    }

    private func appendCandidate(_ candidate: IceCandidatePayload, field: String, roomCode: String) async throws {
        guard var existingRoom = try await room(roomCode: roomCode) else { throw RoomRepositoryError.roomNotFound }
        if field == "cameraCandidates" {
            existingRoom.cameraCandidates.append(candidate)
        } else {
            existingRoom.controllerCandidates.append(candidate)
        }
        try await patch(roomCode: roomCode.normalizedRoomCode, fields: [
            "cameraCandidates": Self.encodeCandidates(existingRoom.cameraCandidates),
            "controllerCandidates": Self.encodeCandidates(existingRoom.controllerCandidates),
            "updatedAt": .timestamp(Date())
        ])
    }

    private func addCandidate(
        _ candidate: IceCandidatePayload,
        collection: String,
        roomCode: String,
        rtcSessionId: String
    ) async throws {
        var components = try makeSubcollectionURL(roomCode: roomCode, collection: collection)
        guard let url = components.url else { throw FirestoreRESTError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(FirestoreDocument(fields: [
            "candidate": .string(candidate.candidate),
            "sdpMid": .string(candidate.sdpMid),
            "sdpMLineIndex": .integer(Int(candidate.sdpMLineIndex)),
            "rtcSessionId": .string(rtcSessionId)
        ]))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        try validate(httpResponse: httpResponse, data: data)
    }

    private func candidates(collection: String, roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        let request = try makeSubcollectionRequest(roomCode: roomCode, collection: collection, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return [] }
        if httpResponse.statusCode == 404 { return [] }
        try validate(httpResponse: httpResponse, data: data)
        let list = try JSONDecoder().decode(FirestoreListResponse.self, from: data)
        return (list.documents ?? []).compactMap { document in
            if let rtcSessionId, document.fields["rtcSessionId"]?.stringValue != rtcSessionId {
                return nil
            }
            return Self.decodeCandidate(document.fields)
        }
    }

    private func clearIceCandidates(roomCode: String) async throws {
        for collection in ["iceCandidatesCamera", "iceCandidatesController"] {
            let request = try makeSubcollectionRequest(roomCode: roomCode, collection: collection, method: "GET")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { continue }
            if httpResponse.statusCode == 404 { continue }
            try validate(httpResponse: httpResponse, data: data)
            let list = try JSONDecoder().decode(FirestoreListResponse.self, from: data)
            for document in list.documents ?? [] {
                guard let name = document.name,
                      let url = URL(string: "https://firestore.googleapis.com/v1/\(name)?key=\(configuration?.apiKey ?? "")") else { continue }
                var deleteRequest = URLRequest(url: url)
                deleteRequest.httpMethod = "DELETE"
                let (deleteData, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
                if let deleteHTTPResponse = deleteResponse as? HTTPURLResponse, deleteHTTPResponse.statusCode != 404 {
                    try validate(httpResponse: deleteHTTPResponse, data: deleteData)
                }
            }
        }
    }

    private nonisolated static func makeRoomCode() -> String { String(Int.random(in: 100_000...999_999)) }

    private nonisolated static func safeAspectRatioMode(_ mode: String) -> String {
        ["full", "4:3", "square"].contains(mode) ? mode : "full"
    }

    private nonisolated static func isQuotaError(_ error: Error) -> Bool {
        error.localizedDescription.contains("RESOURCE_EXHAUSTED") ||
            error.localizedDescription.contains("Quota") ||
            error.localizedDescription.contains("429")
    }

    private func setRoom(_ room: RoomDocument) async throws {
        try await patch(roomCode: room.roomCode, fields: Self.encodeRoom(room))
    }

    private func patch(roomCode: String, fields: [String: FirestoreValue]) async throws {
        var components = try makeDocumentURL(roomCode: roomCode)
        components.queryItems = (components.queryItems ?? []) + fields.keys.map {
            URLQueryItem(name: "updateMask.fieldPaths", value: $0)
        }
        guard let url = components.url else { throw FirestoreRESTError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(FirestoreDocument(fields: fields))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        try validate(httpResponse: httpResponse, data: data)
    }

    private func makeRequest(roomCode: String, method: String) throws -> URLRequest {
        guard let url = try makeDocumentURL(roomCode: roomCode).url else {
            throw FirestoreRESTError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func makeSubcollectionRequest(roomCode: String, collection: String, method: String) throws -> URLRequest {
        guard let url = try makeSubcollectionURL(roomCode: roomCode, collection: collection).url else {
            throw FirestoreRESTError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func makeDocumentURL(roomCode: String) throws -> URLComponents {
        guard let configuration else { throw FirestoreRESTError.invalidConfiguration }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.path = "/v1/projects/\(configuration.projectID)/databases/(default)/documents/\(collectionName)/\(roomCode.normalizedRoomCode)"
        components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
        return components
    }

    private func makeSubcollectionURL(roomCode: String, collection: String) throws -> URLComponents {
        guard let configuration else { throw FirestoreRESTError.invalidConfiguration }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "firestore.googleapis.com"
        components.path = "/v1/projects/\(configuration.projectID)/databases/(default)/documents/\(collectionName)/\(roomCode.normalizedRoomCode)/\(collection)"
        components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
        return components
    }

    private func validate(httpResponse: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw FirestoreRESTError.requestFailed(body)
        }
    }

    private static func encodeRoom(_ room: RoomDocument) -> [String: FirestoreValue] {
        var fields: [String: FirestoreValue] = [
            "roomCode": .string(room.roomCode),
            "status": .string(room.status.rawValue),
            "requestReceived": .bool(room.requestReceived),
            "controllerApproved": .bool(room.controllerApproved),
            "captureRequest": .bool(room.captureRequest != nil),
            "captureRequestId": .integer(room.captureRequest.flatMap { Int($0.id) } ?? 0),
            "captureRequestType": .string(room.captureRequest?.type ?? "photo"),
            "cameraMode": .string(room.cameraMode),
            "aspectRatioMode": .string(room.aspectRatioMode),
            "lensFacing": .string(room.lensFacing.rawValue),
            "zoomLevel": .double(room.zoomLevel),
            "minZoom": .double(room.minZoom),
            "maxZoom": .double(room.maxZoom),
            "flashEnabled": .bool(room.flashEnabled),
            "flashMode": .string(room.flashMode),
            "flashSupported": .bool(room.flashSupported),
            "gridEnabled": .bool(room.gridEnabled),
            "nightModeEnabled": .bool(room.nightModeEnabled),
            "videoHdrSupported": .bool(room.videoHdrSupported),
            "videoHdrEnabled": .bool(room.videoHdrEnabled),
            "toolbarExpanded": .bool(room.toolbarExpanded),
            "focusRequestId": .integer(room.focusRequestId),
            "focusLockEnabled": .bool(room.focusLockEnabled),
            "focusPointX": .double(room.focusPointX),
            "focusPointY": .double(room.focusPointY),
            "exposureMinIndex": .integer(room.exposureMinIndex),
            "exposureMaxIndex": .integer(room.exposureMaxIndex),
            "exposureIndex": .integer(room.exposureIndex),
            "previewWidth": .integer(room.previewWidth),
            "previewHeight": .integer(room.previewHeight),
            "sessionVersion": .integer(room.sessionVersion),
            "cameraCandidates": encodeCandidates(room.cameraCandidates),
            "controllerCandidates": encodeCandidates(room.controllerCandidates),
            "updatedAt": .timestamp(room.updatedAt)
        ]
        if let captureRequest = room.captureRequest {
            fields["captureRequest"] = .map(["id": .string(captureRequest.id), "requestedAt": .timestamp(captureRequest.requestedAt)])
        }
        if let offer = room.offer { fields["offer"] = .string(offer) }
        if let answer = room.answer { fields["answer"] = .string(answer) }
        if let rtcSessionId = room.rtcSessionId { fields["rtcSessionId"] = .string(rtcSessionId) }
        return fields
    }

    private static func decodeRoom(_ data: [String: FirestoreValue]) -> RoomDocument? {
        guard let roomCode = data["roomCode"]?.stringValue else { return nil }
        let captureFields = data["captureRequest"]?.mapValue?.fields
        let captureRequest: CaptureRequest?
        if let captureFields, let id = captureFields["id"]?.stringValue {
            captureRequest = CaptureRequest(
                id: id,
                type: captureFields["type"]?.stringValue ?? "photo",
                requestedAt: captureFields["requestedAt"]?.dateValue ?? Date()
            )
        } else if data["captureRequest"]?.booleanValue == true {
            let id = data["captureRequestId"]?.stringValue ?? String(data["captureRequestId"]?.integerNumberValue ?? 0)
            captureRequest = CaptureRequest(
                id: id,
                type: data["captureRequestType"]?.stringValue ?? "photo",
                requestedAt: Date()
            )
        } else {
            captureRequest = nil
        }
        let flashMode = data["flashMode"]?.stringValue ?? (data["flashEnabled"]?.booleanValue == true ? "on" : "off")
        return RoomDocument(
            roomCode: roomCode,
            status: decodeStatus(data["status"]?.stringValue),
            requestReceived: data["requestReceived"]?.booleanValue ?? false,
            controllerApproved: data["controllerApproved"]?.booleanValue ?? false,
            captureRequest: captureRequest,
            lensFacing: LensFacing(rawValue: data["lensFacing"]?.stringValue ?? "back") ?? .back,
            zoomLevel: data["zoomLevel"]?.numberValue ?? 1.0,
            minZoom: data["minZoom"]?.numberValue ?? 1.0,
            maxZoom: data["maxZoom"]?.numberValue ?? 8.0,
            flashEnabled: data["flashEnabled"]?.booleanValue ?? (flashMode == "on"),
            flashMode: flashMode,
            flashSupported: data["flashSupported"]?.booleanValue ?? true,
            cameraMode: data["cameraMode"]?.stringValue ?? "photo",
            aspectRatioMode: data["aspectRatioMode"]?.stringValue ?? "full",
            gridEnabled: data["gridEnabled"]?.booleanValue ?? false,
            nightModeEnabled: data["nightModeEnabled"]?.booleanValue ?? false,
            videoHdrSupported: data["videoHdrSupported"]?.booleanValue ?? false,
            videoHdrEnabled: data["videoHdrEnabled"]?.booleanValue ?? false,
            toolbarExpanded: data["toolbarExpanded"]?.booleanValue ?? false,
            focusRequestId: data["focusRequestId"]?.integerNumberValue ?? 0,
            focusPointX: data["focusPointX"]?.numberValue ?? 0.5,
            focusPointY: data["focusPointY"]?.numberValue ?? 0.5,
            focusLockEnabled: data["focusLockEnabled"]?.booleanValue ?? false,
            exposureMinIndex: data["exposureMinIndex"]?.integerNumberValue ?? 0,
            exposureMaxIndex: data["exposureMaxIndex"]?.integerNumberValue ?? 0,
            exposureIndex: data["exposureIndex"]?.integerNumberValue ?? 0,
            rtcSessionId: data["rtcSessionId"]?.stringValue,
            sessionVersion: data["sessionVersion"]?.integerNumberValue ?? 0,
            previewWidth: data["previewWidth"]?.integerNumberValue ?? 0,
            previewHeight: data["previewHeight"]?.integerNumberValue ?? 0,
            offer: data["offer"]?.stringValue,
            answer: data["answer"]?.stringValue,
            cameraCandidates: decodeCandidates(data["cameraCandidates"]),
            controllerCandidates: decodeCandidates(data["controllerCandidates"]),
            updatedAt: data["updatedAt"]?.dateValue ?? Date()
        )
    }

    private static func decodeStatus(_ rawValue: String?) -> RoomStatus {
        switch rawValue {
        case "request_received", "waiting_for_approval":
            return .waitingForApproval
        case "connected":
            return .connected
        case "denied":
            return .denied
        case "ended":
            return .ended
        case "disconnected":
            return .disconnected
        default:
            return .created
        }
    }

    private static func firestoreValue(_ value: Any) -> FirestoreValue {
        if let value = value as? FirestoreValue { return value }
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Double { return .double(value) }
        if let value = value as? Int32 { return .integer(Int(value)) }
        if let value = value as? Int { return .integer(value) }
        if let value = value as? Date { return .timestamp(value) }
        return .string(String(describing: value))
    }

    private static func encodeCandidates(_ candidates: [IceCandidatePayload]) -> FirestoreValue {
        .array(candidates.map { candidate in
            .map([
                "candidate": .string(candidate.candidate),
                "sdpMid": .string(candidate.sdpMid),
                "sdpMLineIndex": .integer(Int(candidate.sdpMLineIndex))
            ])
        })
    }

    private static func decodeCandidates(_ value: FirestoreValue?) -> [IceCandidatePayload] {
        guard let values = value?.arrayValue?.values else { return [] }
        return values.compactMap { value in
            guard let fields = value.mapValue?.fields else { return nil }
            return decodeCandidate(fields)
        }
    }

    private static func decodeCandidate(_ fields: [String: FirestoreValue]) -> IceCandidatePayload? {
        guard let candidate = fields["candidate"]?.stringValue,
              let sdpMid = fields["sdpMid"]?.stringValue else { return nil }
        let index = Int32(fields["sdpMLineIndex"]?.integerNumberValue ?? 0)
        return IceCandidatePayload(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: index)
    }
}

struct FirestoreRESTConfiguration: Sendable {
    let projectID: String
    let apiKey: String

    static func load() -> FirestoreRESTConfiguration? {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let projectID = plist["PROJECT_ID"] as? String,
              let apiKey = plist["API_KEY"] as? String else { return nil }
        return FirestoreRESTConfiguration(projectID: projectID, apiKey: apiKey)
    }
}

enum FirestoreRESTError: LocalizedError {
    case invalidConfiguration
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Firestore is missing GoogleService-Info.plist configuration."
        case .requestFailed(let message):
            return message
        }
    }
}

struct FirestoreDocument: Codable {
    var name: String? = nil
    var fields: [String: FirestoreValue]
}

struct FirestoreListResponse: Codable {
    var documents: [FirestoreDocument]?
}

struct FirestoreMapValue: Codable {
    var fields: [String: FirestoreValue]
}

struct FirestoreArrayValue: Codable {
    var values: [FirestoreValue]?
}

struct FirestoreValue: Codable {
    var stringValue: String?
    var booleanValue: Bool?
    var integerValue: String?
    var doubleValue: Double?
    var timestampValue: String?
    var nullValue: String?
    var mapValue: FirestoreMapValue?
    var arrayValue: FirestoreArrayValue?

    var numberValue: Double? {
        if let doubleValue { return doubleValue }
        if let integerValue { return Double(integerValue) }
        return nil
    }

    var integerNumberValue: Int? {
        if let integerValue { return Int(integerValue) }
        if let doubleValue { return Int(doubleValue) }
        return nil
    }

    var dateValue: Date? {
        guard let timestampValue else { return nil }
        return FirestoreValue.isoFormatter.date(from: timestampValue)
    }

    static func string(_ value: String) -> FirestoreValue {
        FirestoreValue(stringValue: value)
    }

    static func bool(_ value: Bool) -> FirestoreValue {
        FirestoreValue(booleanValue: value)
    }

    static func integer(_ value: Int) -> FirestoreValue {
        FirestoreValue(integerValue: String(value))
    }

    static func double(_ value: Double) -> FirestoreValue {
        FirestoreValue(doubleValue: value)
    }

    static func timestamp(_ value: Date) -> FirestoreValue {
        FirestoreValue(timestampValue: isoFormatter.string(from: value))
    }

    static var null: FirestoreValue {
        FirestoreValue(nullValue: "NULL_VALUE")
    }

    static func map(_ fields: [String: FirestoreValue]) -> FirestoreValue {
        FirestoreValue(mapValue: FirestoreMapValue(fields: fields))
    }

    static func array(_ values: [FirestoreValue]) -> FirestoreValue {
        FirestoreValue(arrayValue: FirestoreArrayValue(values: values))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

@MainActor
final class AppServices: ObservableObject {
    let roomRepository: any RoomRepository
    let webRtcSession: WebRtcSessionManager
    private var webRtcCancellable: AnyCancellable?

    init() {
        self.roomRepository = Self.makeRoomRepository()
        self.webRtcSession = WebRtcSessionManager()
        bindWebRtcSession()
    }

    init(roomRepository: any RoomRepository, webRtcSession: WebRtcSessionManager) {
        self.roomRepository = roomRepository
        self.webRtcSession = webRtcSession
        bindWebRtcSession()
    }

    private static func makeRoomRepository() -> any RoomRepository {
        #if canImport(FirebaseFirestore)
        return FirebaseSDKRoomRepository()
        #else
        FirestoreRESTConfiguration.load() == nil ? LocalRoomRepository.shared : FirestoreRoomRepository()
        #endif
    }

    private func bindWebRtcSession() {
        webRtcCancellable = webRtcSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

#if canImport(FirebaseFirestore)
final class FirebaseSDKRoomRepository: @unchecked Sendable, RoomRepository {
    private let db = Firestore.firestore()
    private let collectionName = "rooms"

    func createRoom() async throws -> RoomDocument {
        var code = Self.makeRoomCode()
        while try await room(roomCode: code) != nil { code = Self.makeRoomCode() }
        let room = RoomDocument.initial(roomCode: code)
        try await document(code).setData(Self.encodeRoom(room), merge: true)
        return room
    }

    func room(roomCode: String) async throws -> RoomDocument? {
        let snapshot = try await document(roomCode).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return Self.decodeRoom(data)
    }

    func observeRoom(roomCode: String) async -> AsyncThrowingStream<RoomDocument, Error> {
        AsyncThrowingStream { continuation in
            let listener = document(roomCode).addSnapshotListener { snapshot, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let data = snapshot?.data(), let room = Self.decodeRoom(data) else { return }
                continuation.yield(room)
            }
            continuation.onTermination = { _ in listener.remove() }
        }
    }

    func requestConnection(roomCode: String) async throws {
        try await clearIceCandidates(roomCode: roomCode)
        try await update(roomCode: roomCode, values: [
            "requestReceived": true,
            "controllerApproved": false,
            "status": RoomStatus.waitingForApproval.rawValue,
            "offer": FieldValue.delete(),
            "answer": FieldValue.delete(),
            "rtcSessionId": FieldValue.delete()
        ])
    }

    func approveController(roomCode: String) async throws {
        try await update(roomCode: roomCode, values: [
            "requestReceived": false,
            "controllerApproved": true,
            "status": RoomStatus.connected.rawValue
        ])
    }

    func denyController(roomCode: String) async throws {
        try await update(roomCode: roomCode, values: [
            "controllerApproved": false,
            "status": RoomStatus.denied.rawValue
        ])
    }

    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: [
            "lensFacing": lensFacing.rawValue,
            "zoomLevel": max(1.0, min(8.0, zoomLevel)),
            "flashEnabled": flashEnabled,
            "flashMode": flashEnabled ? "on" : "off"
        ])
    }

    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["gridEnabled": gridEnabled])
    }

    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws {
        try await update(roomCode: roomCode, values: ["aspectRatioMode": Self.safeAspectRatioMode(aspectRatioMode)])
    }

    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int, lockEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: [
            "focusPointX": min(1.0, max(0.0, x)),
            "focusPointY": min(1.0, max(0.0, y)),
            "focusRequestId": requestId,
            "focusLockEnabled": lockEnabled
        ])
    }

    func requestCapture(roomCode: String) async throws {
        let request = CaptureRequest.new()
        try await update(roomCode: roomCode, values: [
            "captureRequest": true,
            "captureRequestId": request.id,
            "captureRequestType": request.type
        ])
    }

    func setOffer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try await update(roomCode: roomCode, values: [
            "offer": sdp,
            "answer": FieldValue.delete(),
            "rtcSessionId": rtcSessionId
        ])
    }

    func setAnswer(_ sdp: String, roomCode: String, rtcSessionId: String) async throws {
        try await update(roomCode: roomCode, values: [
            "answer": sdp,
            "rtcSessionId": rtcSessionId
        ])
    }

    func addCameraCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try await addCandidate(candidate, collection: "iceCandidatesCamera", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func addControllerCandidate(_ candidate: IceCandidatePayload, roomCode: String, rtcSessionId: String) async throws {
        try await addCandidate(candidate, collection: "iceCandidatesController", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func cameraCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        try await candidates(collection: "iceCandidatesCamera", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    func controllerCandidates(roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        try await candidates(collection: "iceCandidatesController", roomCode: roomCode, rtcSessionId: rtcSessionId)
    }

    private func document(_ roomCode: String) -> DocumentReference {
        db.collection(collectionName).document(roomCode.normalizedRoomCode)
    }

    private func update(roomCode: String, values: [String: Any]) async throws {
        try await document(roomCode).updateData(values)
    }

    private func addCandidate(
        _ candidate: IceCandidatePayload,
        collection: String,
        roomCode: String,
        rtcSessionId: String
    ) async throws {
        _ = try await document(roomCode).collection(collection).addDocument(data: [
            "candidate": candidate.candidate,
            "sdpMid": candidate.sdpMid,
            "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            "rtcSessionId": rtcSessionId
        ])
    }

    private func candidates(collection: String, roomCode: String, rtcSessionId: String?) async throws -> [IceCandidatePayload] {
        let snapshot = try await document(roomCode).collection(collection).getDocuments()
        return snapshot.documents.compactMap { document in
            let data = document.data()
            if let rtcSessionId, data["rtcSessionId"] as? String != rtcSessionId {
                return nil
            }
            return Self.decodeCandidate(data)
        }
    }

    private func clearIceCandidates(roomCode: String) async throws {
        for collection in ["iceCandidatesCamera", "iceCandidatesController"] {
            let snapshot = try await document(roomCode).collection(collection).getDocuments()
            for document in snapshot.documents {
                try await document.reference.delete()
            }
        }
    }

    private static func encodeRoom(_ room: RoomDocument) -> [String: Any] {
        [
            "roomCode": room.roomCode,
            "status": room.status.rawValue,
            "requestReceived": room.requestReceived,
            "controllerApproved": room.controllerApproved,
            "captureRequest": room.captureRequest != nil,
            "captureRequestId": room.captureRequest?.id ?? "0",
            "captureRequestType": room.captureRequest?.type ?? "photo",
            "cameraMode": room.cameraMode,
            "aspectRatioMode": room.aspectRatioMode,
            "lensFacing": room.lensFacing.rawValue,
            "zoomLevel": room.zoomLevel,
            "minZoom": room.minZoom,
            "maxZoom": room.maxZoom,
            "flashEnabled": room.flashEnabled,
            "flashMode": room.flashMode,
            "flashSupported": room.flashSupported,
            "gridEnabled": room.gridEnabled,
            "nightModeEnabled": room.nightModeEnabled,
            "videoHdrSupported": room.videoHdrSupported,
            "videoHdrEnabled": room.videoHdrEnabled,
            "toolbarExpanded": room.toolbarExpanded,
            "focusRequestId": room.focusRequestId,
            "focusLockEnabled": room.focusLockEnabled,
            "focusPointX": room.focusPointX,
            "focusPointY": room.focusPointY,
            "exposureMinIndex": room.exposureMinIndex,
            "exposureMaxIndex": room.exposureMaxIndex,
            "exposureIndex": room.exposureIndex,
            "previewWidth": room.previewWidth,
            "previewHeight": room.previewHeight,
            "sessionVersion": room.sessionVersion,
            "updatedAt": Timestamp(date: room.updatedAt),
            "createdAt": Timestamp(date: Date())
        ]
    }

    private static func decodeRoom(_ data: [String: Any]) -> RoomDocument? {
        guard let roomCode = data["roomCode"] as? String else { return nil }
        let flashMode = data["flashMode"] as? String ?? ((data["flashEnabled"] as? Bool) == true ? "on" : "off")
        let captureRequest: CaptureRequest?
        if (data["captureRequest"] as? Bool) == true {
            captureRequest = CaptureRequest(
                id: String(describing: data["captureRequestId"] ?? "0"),
                type: data["captureRequestType"] as? String ?? "photo",
                requestedAt: Date()
            )
        } else {
            captureRequest = nil
        }
        return RoomDocument(
            roomCode: roomCode,
            status: decodeStatus(data["status"] as? String),
            requestReceived: data["requestReceived"] as? Bool ?? false,
            controllerApproved: data["controllerApproved"] as? Bool ?? false,
            captureRequest: captureRequest,
            lensFacing: LensFacing(rawValue: data["lensFacing"] as? String ?? "back") ?? .back,
            zoomLevel: data["zoomLevel"] as? Double ?? 1.0,
            minZoom: data["minZoom"] as? Double ?? 1.0,
            maxZoom: data["maxZoom"] as? Double ?? 8.0,
            flashEnabled: data["flashEnabled"] as? Bool ?? (flashMode == "on"),
            flashMode: flashMode,
            flashSupported: data["flashSupported"] as? Bool ?? true,
            cameraMode: data["cameraMode"] as? String ?? "photo",
            aspectRatioMode: data["aspectRatioMode"] as? String ?? "full",
            gridEnabled: data["gridEnabled"] as? Bool ?? false,
            nightModeEnabled: data["nightModeEnabled"] as? Bool ?? false,
            videoHdrSupported: data["videoHdrSupported"] as? Bool ?? false,
            videoHdrEnabled: data["videoHdrEnabled"] as? Bool ?? false,
            toolbarExpanded: data["toolbarExpanded"] as? Bool ?? false,
            focusRequestId: data["focusRequestId"] as? Int ?? 0,
            focusPointX: data["focusPointX"] as? Double ?? 0.5,
            focusPointY: data["focusPointY"] as? Double ?? 0.5,
            focusLockEnabled: data["focusLockEnabled"] as? Bool ?? false,
            exposureMinIndex: data["exposureMinIndex"] as? Int ?? 0,
            exposureMaxIndex: data["exposureMaxIndex"] as? Int ?? 0,
            exposureIndex: data["exposureIndex"] as? Int ?? 0,
            rtcSessionId: data["rtcSessionId"] as? String,
            sessionVersion: data["sessionVersion"] as? Int ?? 0,
            previewWidth: data["previewWidth"] as? Int ?? 0,
            previewHeight: data["previewHeight"] as? Int ?? 0,
            offer: data["offer"] as? String,
            answer: data["answer"] as? String,
            cameraCandidates: [],
            controllerCandidates: [],
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }

    private static func decodeCandidate(_ data: [String: Any]) -> IceCandidatePayload? {
        guard let candidate = data["candidate"] as? String,
              let sdpMid = data["sdpMid"] as? String else { return nil }
        let index = data["sdpMLineIndex"] as? Int ?? 0
        return IceCandidatePayload(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: Int32(index))
    }

    private static func decodeStatus(_ rawValue: String?) -> RoomStatus {
        switch rawValue {
        case "request_received", "waiting_for_approval":
            return .waitingForApproval
        case "connected":
            return .connected
        case "denied":
            return .denied
        case "ended":
            return .ended
        case "disconnected":
            return .disconnected
        default:
            return .created
        }
    }

    private static func makeRoomCode() -> String {
        String(Int.random(in: 100_000...999_999))
    }

    private static func safeAspectRatioMode(_ mode: String) -> String {
        ["full", "4:3", "square"].contains(mode) ? mode : "full"
    }
}
#endif

@MainActor
protocol WebRtcSessionManaging: AnyObject {
    var state: WebRtcConnectionState { get }
    func startHost(roomCode: String, repository: any RoomRepository) async
    func startController(roomCode: String, repository: any RoomRepository) async
    func stop()
}

enum WebRtcConnectionState: String {
    case idle
    case connecting
    case connected
    case unavailable
    case failed
}

@MainActor
final class WebRtcSessionManager: NSObject, ObservableObject, WebRtcSessionManaging {
    @Published private(set) var state: WebRtcConnectionState = .idle
    #if canImport(WebRTC)
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private var role: WebRtcRole = .host
    private var roomCode: String?
    private var rtcSessionId: String?
    private var repository: (any RoomRepository)?
    private var signalingTask: Task<Void, Never>?
    private var candidatePollingTask: Task<Void, Never>?
    private var appliedRemoteCandidateIDs = Set<String>()
    private var activeCaptureDevice: AVCaptureDevice?
    private var activeLensFacing: LensFacing = .back
    private var activeZoomLevel = 1.0
    private var activeFlashEnabled = false
    private var isRestartingCapture = false
    #endif

    override init() {
        super.init()
        #if canImport(WebRTC)
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        #endif
    }

    func startHost(roomCode: String, repository: any RoomRepository) async {
        #if canImport(WebRTC)
        guard state == .idle || state == .unavailable || state == .failed else { return }
        state = .connecting
        self.role = .host
        self.roomCode = roomCode
        self.repository = repository
        self.rtcSessionId = nil

        do {
            let peerConnection = try makePeerConnection()
            self.peerConnection = peerConnection
            try startCameraTrack(on: peerConnection)
            observeSignaling(roomCode: roomCode, repository: repository)
        } catch {
            state = .failed
        }
        #else
        state = .unavailable
        #endif
    }

    func startController(roomCode: String, repository: any RoomRepository) async {
        #if canImport(WebRTC)
        guard state == .idle || state == .unavailable || state == .failed else { return }
        state = .connecting
        self.role = .controller
        self.roomCode = roomCode
        self.repository = repository
        let rtcSessionId = UUID().uuidString
        self.rtcSessionId = rtcSessionId

        do {
            let peerConnection = try makePeerConnection()
            self.peerConnection = peerConnection
            let offer = try await makeOffer(on: peerConnection)
            try await peerConnection.setLocalDescriptionAsync(offer)
            try await repository.setOffer(offer.sdp, roomCode: roomCode, rtcSessionId: rtcSessionId)
            observeSignaling(roomCode: roomCode, repository: repository)
        } catch {
            state = .failed
        }
        #else
        state = .unavailable
        #endif
    }

    func stop() {
        #if canImport(WebRTC)
        signalingTask?.cancel()
        signalingTask = nil
        candidatePollingTask?.cancel()
        candidatePollingTask = nil
        cameraCapturer?.stopCapture()
        cameraCapturer = nil
        activeCaptureDevice = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        #endif
        state = .idle
    }

    func applyCameraControls(lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        let clampedZoom = max(1.0, min(8.0, zoomLevel))
        let shouldSwitchLens = activeLensFacing != lensFacing
        activeZoomLevel = clampedZoom
        activeFlashEnabled = flashEnabled

        if shouldSwitchLens {
            activeLensFacing = lensFacing
            guard !isRestartingCapture else { return }
            isRestartingCapture = true
            cameraCapturer.stopCapture { [weak self, weak cameraCapturer] in
                Task { @MainActor in
                    guard let self, let cameraCapturer else { return }
                    defer { self.isRestartingCapture = false }
                    do {
                        try self.startCapture(cameraCapturer, lensFacing: lensFacing)
                    } catch {
                        self.state = .failed
                    }
                }
            }
        } else {
            applyDeviceControls(zoomLevel: clampedZoom)
        }
        #endif
    }

    func applyFocusPoint(x: Double, y: Double, lockEnabled: Bool) {
        #if canImport(WebRTC)
        guard role == .host, let device = activeCaptureDevice else { return }
        do {
            try device.lockForConfiguration()
            let point = CGPoint(x: min(1.0, max(0.0, x)), y: min(1.0, max(0.0, y)))
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = lockEnabled ? .locked : .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = lockEnabled ? .locked : .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
        #endif
    }

    func pauseHostVideoCapture() async {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        await withCheckedContinuation { continuation in
            cameraCapturer.stopCapture {
                continuation.resume()
            }
        }
        activeCaptureDevice = nil
        #endif
    }

    func resumeHostVideoCapture() {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        do {
            try startCapture(cameraCapturer, lensFacing: activeLensFacing)
        } catch {
            state = .failed
        }
        #endif
    }

    #if canImport(WebRTC)
    private func makePeerConnection() throws -> RTCPeerConnection {
        guard let factory else { throw WebRtcSessionError.factoryUnavailable }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun2.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun3.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun4.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:80?transport=udp"], username: "openrelayproject", credential: "openrelayproject"),
            RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:443?transport=tcp"], username: "openrelayproject", credential: "openrelayproject")
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw WebRtcSessionError.peerConnectionUnavailable
        }
        return peerConnection
    }

    private func startCameraTrack(on peerConnection: RTCPeerConnection) throws {
        guard let factory else { throw WebRtcSessionError.factoryUnavailable }
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "camera-video")
        if let sender = peerConnection.add(videoTrack, streamIds: ["camera-stream"]) {
            configureVideoSender(sender)
        }

        cameraCapturer = capturer
        localVideoTrack = videoTrack
        try startCapture(capturer, lensFacing: activeLensFacing)
    }

    private func startCapture(_ capturer: RTCCameraVideoCapturer, lensFacing: LensFacing) throws {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let position: AVCaptureDevice.Position = lensFacing == .back ? .back : .front
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let preferredFormats = formats.sorted { lhs, rhs in
            let lhsSize = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsSize = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsDistance = abs(Int(lhsSize.width) - 640) + abs(Int(lhsSize.height) - 360)
            let rhsDistance = abs(Int(rhsSize.width) - 640) + abs(Int(rhsSize.height) - 360)
            return lhsDistance < rhsDistance
        }
        guard let format = preferredFormats.first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let supportedFPS = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max() ?? 15
        capturer.startCapture(with: device, format: format, fps: min(supportedFPS, 15))
        activeCaptureDevice = device
        applyDeviceControls(zoomLevel: activeZoomLevel)
    }

    private func applyDeviceControls(zoomLevel: Double) {
        guard let device = activeCaptureDevice else { return }
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(maxZoom, zoomLevel))
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func configureVideoSender(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        parameters.encodings.forEach { encoding in
            encoding.minBitrateBps = NSNumber(value: 300_000)
            encoding.maxBitrateBps = NSNumber(value: 850_000)
            encoding.maxFramerate = NSNumber(value: 15)
        }
        sender.parameters = parameters
    }

    private func makeOffer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveVideo": "true"], optionalConstraints: nil)
        return try await peerConnection.offerAsync(for: constraints)
    }

    private func makeAnswer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveVideo": "true"], optionalConstraints: nil)
        return try await peerConnection.answerAsync(for: constraints)
    }

    private func observeSignaling(roomCode: String, repository: any RoomRepository) {
        signalingTask?.cancel()
        candidatePollingTask?.cancel()
        signalingTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await room in await repository.observeRoom(roomCode: roomCode) {
                    await self.apply(room: room, repository: repository)
                }
            } catch {
                await MainActor.run { self.state = .failed }
            }
        }
        candidatePollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.applyRemoteCandidates(roomCode: roomCode, repository: repository)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func apply(room: RoomDocument, repository: any RoomRepository) async {
        guard let peerConnection else { return }
        do {
            if rtcSessionId == nil, let roomRtcSessionId = room.rtcSessionId {
                rtcSessionId = roomRtcSessionId
            }

            if role == .host, peerConnection.remoteDescription == nil, let offerSdp = room.offer {
                try await peerConnection.setRemoteDescriptionAsync(RTCSessionDescription(type: .offer, sdp: offerSdp))
                let answer = try await makeAnswer(on: peerConnection)
                try await peerConnection.setLocalDescriptionAsync(answer)
                let activeSessionId = room.rtcSessionId ?? rtcSessionId ?? UUID().uuidString
                rtcSessionId = activeSessionId
                try await repository.setAnswer(answer.sdp, roomCode: room.roomCode, rtcSessionId: activeSessionId)
                state = .connected
            }

            if role == .controller, peerConnection.remoteDescription == nil, let answerSdp = room.answer {
                try await peerConnection.setRemoteDescriptionAsync(RTCSessionDescription(type: .answer, sdp: answerSdp))
                state = .connected
            }

            await applyRemoteCandidates(roomCode: room.roomCode, repository: repository)
        } catch {
            state = .failed
        }
    }

    private func applyRemoteCandidates(roomCode: String, repository: any RoomRepository) async {
        guard let peerConnection else { return }
        do {
            let candidates = role == .host
                ? try await repository.controllerCandidates(roomCode: roomCode, rtcSessionId: rtcSessionId)
                : try await repository.cameraCandidates(roomCode: roomCode, rtcSessionId: rtcSessionId)
            for payload in candidates where !appliedRemoteCandidateIDs.contains(payload.id) {
                appliedRemoteCandidateIDs.insert(payload.id)
                let candidate = RTCIceCandidate(sdp: payload.candidate, sdpMLineIndex: payload.sdpMLineIndex, sdpMid: payload.sdpMid)
                try await peerConnection.addIceCandidateAsync(candidate)
            }
        } catch {
            // Candidate polling is best-effort; room polling handles fatal signaling failures.
        }
    }
    #endif
}

enum WebRtcRole {
    case host
    case controller
}

enum WebRtcSessionError: Error {
    case factoryUnavailable
    case peerConnectionUnavailable
    case cameraUnavailable
}

#if canImport(WebRTC)
extension WebRtcSessionManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            Task { @MainActor in self.remoteVideoTrack = track }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            Task { @MainActor in self.remoteVideoTrack = track }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let roomCode, let repository else { return }
            let activeSessionId = rtcSessionId ?? UUID().uuidString
            rtcSessionId = activeSessionId
            let payload = IceCandidatePayload(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid ?? "0",
                sdpMLineIndex: candidate.sdpMLineIndex
            )
            do {
                if role == .host {
                    try await repository.addCameraCandidate(payload, roomCode: roomCode, rtcSessionId: activeSessionId)
                } else {
                    try await repository.addControllerCandidate(payload, roomCode: roomCode, rtcSessionId: activeSessionId)
                }
            } catch {
                state = .failed
            }
        }
    }
}

extension RTCPeerConnection {
    func offerAsync(for constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WebRtcSessionError.peerConnectionUnavailable)
                }
            }
        }
    }

    func answerAsync(for constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WebRtcSessionError.peerConnectionUnavailable)
                }
            }
        }
    }

    func setLocalDescriptionAsync(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func setRemoteDescriptionAsync(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func addIceCandidateAsync(_ candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif

@MainActor
final class CameraController: NSObject, ObservableObject {
    enum PermissionState: Equatable {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var isRunning = false
    @Published private(set) var lastCapturedImage: UIImage?
    @Published private(set) var lastSavedPhotoURL: URL?
    @Published private(set) var photoSaveMessage: String?
    @Published var lensFacing: LensFacing = .back
    @Published var zoomLevel: Double = 1.0
    @Published var flashEnabled = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var pendingPhotoDelegates: [Int64: PhotoCaptureDelegate] = [:]

    override init() {
        super.init()
        permissionState = Self.currentPermissionState()
    }

    func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
            configureAndStart()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
            if granted { configureAndStart() }
        default:
            permissionState = .denied
        }
    }

    func prepareForPhotoCapture(lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
            guard granted else { return false }
        default:
            permissionState = .denied
            return false
        }

        self.lensFacing = lensFacing
        self.zoomLevel = max(1.0, min(8.0, zoomLevel))
        self.flashEnabled = flashEnabled
        return await configureAndStartForPhotoCapture()
    }

    func stop() {
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    func apply(lensFacing: LensFacing, zoomLevel: Double, flashEnabled: Bool) {
        let clampedZoom = max(1.0, min(8.0, zoomLevel))
        let shouldSwitchLens = self.lensFacing != lensFacing
        self.lensFacing = lensFacing
        self.zoomLevel = clampedZoom
        self.flashEnabled = flashEnabled
        shouldSwitchLens ? configureAndStart() : applyZoom(clampedZoom)
    }

    func switchLens() {
        apply(lensFacing: lensFacing == .back ? .front : .back, zoomLevel: zoomLevel, flashEnabled: flashEnabled)
    }

    func capturePhoto(completion: ((UIImage?) -> Void)? = nil) {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.on) {
            settings.flashMode = flashEnabled ? .on : .off
        }
        let uniqueID = Int64(settings.uniqueID)
        let delegate = PhotoCaptureDelegate { [weak self] image in
            Task { @MainActor in
                self?.lastCapturedImage = image
                await self?.saveCapturedPhoto(image)
                self?.pendingPhotoDelegates[uniqueID] = nil
                completion?(image)
            }
        }
        pendingPhotoDelegates[uniqueID] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func configureAndStart() {
        let selectedLens = lensFacing
        let selectedZoom = zoomLevel
        let session = session
        let photoOutput = photoOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if let currentInput = self.currentInput { session.removeInput(currentInput) }
            do {
                let device = try Self.makeDevice(for: selectedLens)
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    return
                }
                session.addInput(input)
                self.currentInput = input
                if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                }
                session.commitConfiguration()
                self.applyZoomOnQueue(selectedZoom, device: device)
                if !session.isRunning { session.startRunning() }
                Task { @MainActor in self.isRunning = session.isRunning }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in self.permissionState = .denied }
            }
        }
    }

    private func configureAndStartForPhotoCapture() async -> Bool {
        let selectedLens = lensFacing
        let selectedZoom = zoomLevel
        let session = session
        let photoOutput = photoOutput

        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                session.beginConfiguration()
                session.sessionPreset = .photo
                if let currentInput = self.currentInput { session.removeInput(currentInput) }

                do {
                    let device = try Self.makeDevice(for: selectedLens)
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(returning: false)
                        return
                    }
                    session.addInput(input)
                    self.currentInput = input
                    if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                        session.addOutput(photoOutput)
                    }
                    session.commitConfiguration()
                    self.applyZoomOnQueue(selectedZoom, device: device)
                    if !session.isRunning { session.startRunning() }
                    let running = session.isRunning
                    Task { @MainActor in self.isRunning = running }
                    continuation.resume(returning: running)
                } catch {
                    session.commitConfiguration()
                    Task { @MainActor in self.permissionState = .denied }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func applyZoom(_ zoomLevel: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyZoomOnQueue(zoomLevel, device: device)
        }
    }

    private func applyZoomOnQueue(_ zoomLevel: Double, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(maxZoom, zoomLevel))
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private static func currentPermissionState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static func makeDevice(for lensFacing: LensFacing) throws -> AVCaptureDevice {
        let position: AVCaptureDevice.Position = lensFacing == .back ? .back : .front
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) { return device }
        throw AVError(.deviceNotConnected)
    }

    private func saveCapturedPhoto(_ image: UIImage?) async {
        guard let image else {
            photoSaveMessage = "Capture failed."
            return
        }

        do {
            lastSavedPhotoURL = try saveToDocuments(image)
        } catch {
            photoSaveMessage = "Photo captured, but local save failed."
        }

        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            photoSaveMessage = "Saved in app storage. Add Photos permission to save to Camera Roll."
            return
        }

        do {
            try await saveToPhotoLibrary(image)
            photoSaveMessage = "Saved to Photos."
        } catch {
            photoSaveMessage = "Saved in app storage. Photos save failed: \(error.localizedDescription)"
        }
    }

    private func saveToDocuments(_ image: UIImage) throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let safeTimestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("AI-Camera-\(safeTimestamp).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func saveToPhotoLibrary(_ image: UIImage) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorized: Bool
        switch status {
        case .authorized, .limited:
            authorized = true
        case .notDetermined:
            let requestedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            authorized = requestedStatus == .authorized || requestedStatus == .limited
        default:
            authorized = false
        }

        guard authorized else {
            throw CocoaError(.userCancelled)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            completion(nil)
            return
        }
        completion(UIImage(data: data))
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraCircleButton: View {
    let systemName: String
    var size: CGFloat = 48
    var role: ButtonRole?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(isSelected ? Color.white : Color.black.opacity(0.42), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                .foregroundStyle(isSelected ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

struct CameraStatusPill: View {
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(primary)
                .font(.headline)
                .lineLimit(1)
            Text(secondary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }
}

struct CameraGridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for index in 1...2 {
                    let x = width * CGFloat(index) / 3.0
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                    let y = height * CGFloat(index) / 3.0
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(.white.opacity(0.38), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

struct FocusReticleView: View {
    let point: CGPoint

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 6)
                .stroke(.yellow, lineWidth: 2)
                .frame(width: 72, height: 72)
                .position(
                    x: point.x * geometry.size.width,
                    y: point.y * geometry.size.height
                )
        }
        .allowsHitTesting(false)
    }
}

extension String {
    var nextCameraAspectRatioMode: String {
        switch self {
        case "full": return "4:3"
        case "4:3": return "square"
        default: return "full"
        }
    }

    var cameraAspectRatioLabel: String {
        switch self {
        case "4:3": return "4:3"
        case "square": return "1:1"
        default: return "Full"
        }
    }

    var cameraAspectRatioValue: CGFloat? {
        switch self {
        case "4:3": return 3.0 / 4.0
        case "square": return 1.0
        default: return nil
        }
    }
}

#if canImport(WebRTC)
struct RemoteVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.update(track: track, renderer: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var currentTrack: RTCVideoTrack?

        func update(track: RTCVideoTrack?, renderer: RTCMTLVideoView) {
            guard currentTrack !== track else { return }
            currentTrack?.remove(renderer)
            currentTrack = track
            track?.add(renderer)
        }
    }
}
#endif

struct ContentView: View {
    @StateObject private var services = AppServices()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            HomeScreen(path: $path)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .cameraHost(let roomCode):
                        CameraHostScreen(roomCode: roomCode)
                    case .controllerEntry:
                        ControllerEntryScreen(path: $path)
                    case .waitingForApproval(let roomCode):
                        WaitingForApprovalScreen(roomCode: roomCode)
                    }
                }
        }
        .environmentObject(services)
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var services: AppServices
    @Binding var path: NavigationPath
    @State private var isCreatingRoom = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("AI Camera Assistant")
                    .font(.largeTitle.bold())
                Text("Create a camera room or connect as the controller.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                Button { createRoom() } label: {
                    Label(isCreatingRoom ? "Creating Room" : "Host Camera", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isCreatingRoom)

                Button { path.append(AppRoute.controllerEntry) } label: {
                    Label("Control Camera", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func createRoom() {
        isCreatingRoom = true
        errorMessage = nil
        Task {
            do {
                let room = try await services.roomRepository.createRoom()
                path.append(AppRoute.cameraHost(roomCode: room.roomCode))
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreatingRoom = false
        }
    }
}

struct ControllerEntryScreen: View {
    @EnvironmentObject private var services: AppServices
    @Binding var path: NavigationPath
    @State private var roomCode = ""
    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Room") {
                TextField("Room code", text: $roomCode)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.characters)

                Button { requestConnection() } label: {
                    Label(isRequesting ? "Requesting" : "Request Access", systemImage: "arrow.right.circle.fill")
                }
                .disabled(roomCode.normalizedRoomCode.isEmpty || isRequesting)
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Control Camera")
    }

    private func requestConnection() {
        isRequesting = true
        errorMessage = nil
        let code = roomCode.normalizedRoomCode
        Task {
            do {
                guard try await services.roomRepository.room(roomCode: code) != nil else { throw RoomRepositoryError.roomNotFound }
                try await services.roomRepository.requestConnection(roomCode: code)
                path.append(AppRoute.waitingForApproval(roomCode: code))
            } catch {
                errorMessage = error.localizedDescription
            }
            isRequesting = false
        }
    }
}

struct CameraHostScreen: View {
    let roomCode: String

    @EnvironmentObject private var services: AppServices
    @StateObject private var camera = CameraController()
    @State private var room: RoomDocument?
    @State private var errorMessage: String?
    @State private var lastHandledCaptureRequestId: String?
    @State private var isHandlingRemoteCapture = false
    @State private var lastHandledFocusRequestId = 0
    @State private var focusReticlePoint: CGPoint?

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
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var hostPreview: some View {
        ZStack {
            #if canImport(WebRTC)
            if let localVideoTrack = services.webRtcSession.localVideoTrack {
                RemoteVideoView(track: localVideoTrack)
            } else {
                CameraPreviewView(session: camera.session)
            }
            #else
            CameraPreviewView(session: camera.session)
            #endif
            if room?.gridEnabled == true {
                CameraGridOverlay()
            }
            if let focusReticlePoint {
                FocusReticleView(point: focusReticlePoint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
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
                camera.switchLens()
                publishCurrentControls()
            }

            CameraCircleButton(
                systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash",
                isSelected: camera.flashEnabled
            ) {
                camera.flashEnabled.toggle()
                publishCurrentControls()
            }

            CameraCircleButton(systemName: "square.grid.3x3", isSelected: room?.gridEnabled == true) {
                updateGridEnabled(!(room?.gridEnabled ?? false))
            }

            CameraCircleButton(systemName: "aspectratio") {
                updateAspectRatioMode((room?.aspectRatioMode ?? "full").nextCameraAspectRatioMode)
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
                Text("Photo")
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1fx", camera.zoomLevel))
                Text(camera.flashEnabled ? "Flash On" : "Flash Off")
                Text((room?.aspectRatioMode ?? "full").cameraAspectRatioLabel)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.42), in: Capsule())

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
        case .connected: return "Controller connected"
        case .denied: return "Controller denied"
        case .disconnected: return "Disconnected"
        case .ended: return "Session ended"
        }
    }

    private func observeRoom() async {
        do {
            for try await nextRoom in await services.roomRepository.observeRoom(roomCode: roomCode) {
                room = nextRoom
                if services.webRtcSession.state == .idle {
                    camera.apply(lensFacing: nextRoom.lensFacing, zoomLevel: nextRoom.zoomLevel, flashEnabled: nextRoom.flashEnabled)
                } else {
                    services.webRtcSession.applyCameraControls(
                        lensFacing: nextRoom.lensFacing,
                        zoomLevel: nextRoom.zoomLevel,
                        flashEnabled: nextRoom.flashEnabled
                    )
                }
                handleFocusRequest(nextRoom)
                handleCaptureRequest(nextRoom.captureRequest)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleCaptureRequest(_ request: CaptureRequest?) {
        guard let request, request.id != lastHandledCaptureRequestId else { return }
        lastHandledCaptureRequestId = request.id
        guard !isHandlingRemoteCapture else { return }
        isHandlingRemoteCapture = true

        Task {
            if services.webRtcSession.state != .idle {
                await services.webRtcSession.pauseHostVideoCapture()
                let ready = await camera.prepareForPhotoCapture(
                    lensFacing: room?.lensFacing ?? camera.lensFacing,
                    zoomLevel: room?.zoomLevel ?? camera.zoomLevel,
                    flashEnabled: room?.flashEnabled ?? camera.flashEnabled
                )
                guard ready else {
                    services.webRtcSession.resumeHostVideoCapture()
                    isHandlingRemoteCapture = false
                    return
                }
                camera.capturePhoto { _ in
                    camera.stop()
                    services.webRtcSession.resumeHostVideoCapture()
                    isHandlingRemoteCapture = false
                }
            } else {
                camera.capturePhoto { _ in
                    isHandlingRemoteCapture = false
                }
            }
        }
    }

    private func handleFocusRequest(_ room: RoomDocument) {
        guard room.focusRequestId != 0, room.focusRequestId != lastHandledFocusRequestId else { return }
        lastHandledFocusRequestId = room.focusRequestId
        let point = CGPoint(x: room.focusPointX, y: room.focusPointY)
        focusReticlePoint = point
        services.webRtcSession.applyFocusPoint(x: point.x, y: point.y, lockEnabled: room.focusLockEnabled)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if focusReticlePoint == point {
                focusReticlePoint = nil
            }
        }
    }

    private func updateApproval(approved: Bool) {
        Task {
            do {
                if approved {
                    try await services.roomRepository.approveController(roomCode: roomCode)
                    camera.stop()
                    try await Task.sleep(for: .milliseconds(250))
                    await services.webRtcSession.startHost(roomCode: roomCode, repository: services.roomRepository)
                } else {
                    try await services.roomRepository.denyController(roomCode: roomCode)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publishCurrentControls() {
        Task {
            try? await services.roomRepository.updateControls(roomCode: roomCode, lensFacing: camera.lensFacing, zoomLevel: camera.zoomLevel, flashEnabled: camera.flashEnabled)
        }
    }

    private func updateGridEnabled(_ enabled: Bool) {
        Task { try? await services.roomRepository.updateGridEnabled(roomCode: roomCode, gridEnabled: enabled) }
    }

    private func updateAspectRatioMode(_ mode: String) {
        Task { try? await services.roomRepository.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: mode) }
    }
}

struct WaitingForApprovalScreen: View {
    let roomCode: String

    @EnvironmentObject private var services: AppServices
    @State private var room: RoomDocument?
    @State private var lensFacing: LensFacing = .back
    @State private var zoomLevel = 1.0
    @State private var flashEnabled = false
    @State private var errorMessage: String?
    @State private var zoomPublishTask: Task<Void, Never>?
    @State private var focusReticlePoint: CGPoint?

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
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await observeRoom() }
        .onDisappear { zoomPublishTask?.cancel() }
    }

    private var previewSurface: some View {
        GeometryReader { geometry in
            ZStack {
            Color.black
            #if canImport(WebRTC)
            if let remoteVideoTrack = services.webRtcSession.remoteVideoTrack {
                RemoteVideoView(track: remoteVideoTrack)
            } else {
                previewStatusOverlay
            }
            #else
            previewStatusOverlay
            #endif
                if room?.gridEnabled == true {
                    CameraGridOverlay()
                }
                if let focusReticlePoint {
                    FocusReticleView(point: focusReticlePoint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard room?.controllerApproved == true else { return }
                        let x = min(1.0, max(0.0, value.location.x / max(geometry.size.width, 1)))
                        let y = min(1.0, max(0.0, value.location.y / max(geometry.size.height, 1)))
                        sendFocusRequest(x: x, y: y)
                    }
            )
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
        guard room?.controllerApproved == true else { return "Waiting for host approval" }
        switch services.webRtcSession.state {
        case .unavailable:
            return "WebRTC package is not linked to this app target"
        case .connecting:
            return "Starting live preview"
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
            zoomStrip

            HStack {
                Spacer()
                shutterButton
                Spacer()
            }

            HStack(spacing: 18) {
                Text("Video")
                    .foregroundStyle(.white.opacity(0.55))
                Text("Photo")
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
                Text("Portrait")
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.42), in: Capsule())

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var controllerToolRail: some View {
        VStack(spacing: 14) {
            CameraCircleButton(systemName: lensFacing == .back ? "camera.rotate" : "camera.rotate.fill") {
                lensFacing = lensFacing == .back ? .front : .back
                publishControls()
            }

            CameraCircleButton(
                systemName: flashEnabled ? "bolt.fill" : "bolt.slash",
                isSelected: flashEnabled
            ) {
                flashEnabled.toggle()
                publishControls()
            }

            CameraCircleButton(systemName: "square.grid.3x3", isSelected: room?.gridEnabled == true) {
                updateGridEnabled(!(room?.gridEnabled ?? false))
            }

            CameraCircleButton(systemName: "aspectratio") {
                updateAspectRatioMode((room?.aspectRatioMode ?? "full").nextCameraAspectRatioMode)
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
                    .fill(.white)
                    .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture photo")
    }

    private var statusText: String {
        guard let room else { return "Connecting to room" }
        switch room.status {
        case .created, .waitingForApproval: return "Host approval required"
        case .connected: return "Connected"
        case .denied: return "Request denied"
        case .disconnected: return "Disconnected"
        case .ended: return "Session ended"
        }
    }

    private func observeRoom() async {
        do {
            for try await nextRoom in await services.roomRepository.observeRoom(roomCode: roomCode) {
                room = nextRoom
                lensFacing = nextRoom.lensFacing
                zoomLevel = nextRoom.zoomLevel
                flashEnabled = nextRoom.flashEnabled
                if nextRoom.controllerApproved {
                    await services.webRtcSession.startController(roomCode: roomCode, repository: services.roomRepository)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publishControls() {
        zoomPublishTask?.cancel()
        Task {
            do {
                try await services.roomRepository.updateControls(roomCode: roomCode, lensFacing: lensFacing, zoomLevel: zoomLevel, flashEnabled: flashEnabled)
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
                try await services.roomRepository.updateControls(roomCode: roomCode, lensFacing: lensFacing, zoomLevel: zoomLevel, flashEnabled: flashEnabled)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func requestCapture() {
        Task {
            do {
                try await services.roomRepository.requestCapture(roomCode: roomCode)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
            try? await Task.sleep(for: .seconds(1))
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
                    requestId: Int(Date().timeIntervalSince1970 * 1000),
                    lockEnabled: false
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
