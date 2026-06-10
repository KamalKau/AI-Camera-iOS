@preconcurrency import AVFoundation
import Combine
import CoreImage
import CoreMotion
import ImageIO
import Photos
import SwiftUI
import UIKit
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
#if canImport(WebRTC)
import WebRTC
#endif

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
            room.captureRequest = nil
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

    func endSession(roomCode: String) async throws {
        try update(roomCode: roomCode) { room in
            room.requestReceived = false
            room.controllerApproved = false
            room.status = .ended
            room.offer = nil
            room.answer = nil
            room.rtcSessionId = nil
            room.cameraCandidates = []
            room.controllerCandidates = []
        }
    }

    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async throws {
        let safeFlashMode = Self.safeFlashMode(flashMode)
        try update(roomCode: roomCode) { room in
            room.lensFacing = lensFacing
            room.zoomLevel = max(1.0, min(8.0, zoomLevel))
            room.flashEnabled = safeFlashMode != "off"
            room.flashMode = safeFlashMode
        }
    }

    func updateCameraMode(roomCode: String, cameraMode: String) async throws {
        try update(roomCode: roomCode) { $0.cameraMode = Self.safeCameraMode(cameraMode) }
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

    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws {
        try update(roomCode: roomCode) { $0.exposureIndex = min(8, max(-8, exposureIndex)) }
    }

    func requestCapture(roomCode: String, type: String) async throws {
        try update(roomCode: roomCode) { $0.captureRequest = .new(type: Self.safeCaptureRequestType(type)) }
    }

    func resetCaptureRequest(roomCode: String) async throws {
        try update(roomCode: roomCode) { $0.captureRequest = nil }
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

    private nonisolated static func safeCameraMode(_ mode: String) -> String {
        ["photo", "video"].contains(mode) ? mode : "photo"
    }

    private nonisolated static func safeFlashMode(_ mode: String) -> String {
        ["off", "auto", "on"].contains(mode) ? mode : "off"
    }

    private nonisolated static func safeCaptureRequestType(_ type: String) -> String {
        ["photo", "video_start", "video_stop"].contains(type) ? type : "photo"
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

    func endSession(roomCode: String) async throws {
        try await clearIceCandidates(roomCode: roomCode)
        try await update(roomCode: roomCode, values: [
            "requestReceived": false,
            "controllerApproved": false,
            "status": RoomStatus.ended.rawValue,
            "captureRequest": false,
            "captureRequestId": 0,
            "captureRequestType": "photo",
            "offer": FirestoreValue.null,
            "answer": FirestoreValue.null,
            "rtcSessionId": FirestoreValue.null
        ])
    }

    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async throws {
        let safeFlashMode = Self.safeFlashMode(flashMode)
        try await update(roomCode: roomCode, values: [
            "lensFacing": lensFacing.rawValue,
            "zoomLevel": max(1.0, min(8.0, zoomLevel)),
            "flashEnabled": safeFlashMode != "off",
            "flashMode": safeFlashMode
        ])
    }

    func updateCameraMode(roomCode: String, cameraMode: String) async throws {
        try await update(roomCode: roomCode, values: ["cameraMode": Self.safeCameraMode(cameraMode)])
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

    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws {
        try await update(roomCode: roomCode, values: ["exposureIndex": min(8, max(-8, exposureIndex))])
    }

    func requestCapture(roomCode: String, type: String) async throws {
        let request = CaptureRequest.new(type: Self.safeCaptureRequestType(type))
        try await update(roomCode: roomCode, values: [
            "captureRequest": true,
            "captureRequestId": request.id,
            "captureRequestType": request.type
        ])
    }

    func resetCaptureRequest(roomCode: String) async throws {
        try await update(roomCode: roomCode, values: [
            "captureRequest": false,
            "captureRequestId": 0,
            "captureRequestType": "photo"
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

    private nonisolated static func safeCameraMode(_ mode: String) -> String {
        ["photo", "video"].contains(mode) ? mode : "photo"
    }

    private nonisolated static func safeFlashMode(_ mode: String) -> String {
        ["off", "auto", "on"].contains(mode) ? mode : "off"
    }

    private nonisolated static func safeCaptureRequestType(_ type: String) -> String {
        ["photo", "video_start", "video_stop"].contains(type) ? type : "photo"
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
            "streamQualityMode": .string(room.streamQualityMode.rawValue),
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
        let flashMode = Self.safeFlashMode(data["flashMode"]?.stringValue ?? (data["flashEnabled"]?.booleanValue == true ? "on" : "off"))
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
            streamQualityMode: StreamQualityMode(rawValue: data["streamQualityMode"]?.stringValue ?? "") ?? .lowLatency,
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

    func endSession(roomCode: String) async throws {
        try await clearIceCandidates(roomCode: roomCode)
        try await update(roomCode: roomCode, values: [
            "requestReceived": false,
            "controllerApproved": false,
            "status": RoomStatus.ended.rawValue,
            "captureRequest": false,
            "captureRequestId": "0",
            "captureRequestType": "photo",
            "offer": FieldValue.delete(),
            "answer": FieldValue.delete(),
            "rtcSessionId": FieldValue.delete()
        ])
    }

    func updateControls(roomCode: String, lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async throws {
        let safeFlashMode = Self.safeFlashMode(flashMode)
        try await update(roomCode: roomCode, values: [
            "lensFacing": lensFacing.rawValue,
            "zoomLevel": max(1.0, min(8.0, zoomLevel)),
            "flashEnabled": safeFlashMode != "off",
            "flashMode": safeFlashMode
        ])
    }

    func updateCameraMode(roomCode: String, cameraMode: String) async throws {
        try await update(roomCode: roomCode, values: ["cameraMode": Self.safeCameraMode(cameraMode)])
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

    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws {
        try await update(roomCode: roomCode, values: ["exposureIndex": min(8, max(-8, exposureIndex))])
    }

    func requestCapture(roomCode: String, type: String) async throws {
        let request = CaptureRequest.new(type: Self.safeCaptureRequestType(type))
        try await update(roomCode: roomCode, values: [
            "captureRequest": true,
            "captureRequestId": request.id,
            "captureRequestType": request.type
        ])
    }

    func resetCaptureRequest(roomCode: String) async throws {
        try await update(roomCode: roomCode, values: [
            "captureRequest": false,
            "captureRequestId": "0",
            "captureRequestType": "photo"
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
            "streamQualityMode": room.streamQualityMode.rawValue,
            "previewWidth": room.previewWidth,
            "previewHeight": room.previewHeight,
            "sessionVersion": room.sessionVersion,
            "updatedAt": Timestamp(date: room.updatedAt),
            "createdAt": Timestamp(date: Date())
        ]
    }

    private static func decodeRoom(_ data: [String: Any]) -> RoomDocument? {
        guard let roomCode = data["roomCode"] as? String else { return nil }
        let flashMode = Self.safeFlashMode(data["flashMode"] as? String ?? ((data["flashEnabled"] as? Bool) == true ? "on" : "off"))
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
            streamQualityMode: StreamQualityMode(rawValue: data["streamQualityMode"] as? String ?? "") ?? .lowLatency,
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

    private static func safeCameraMode(_ mode: String) -> String {
        ["photo", "video"].contains(mode) ? mode : "photo"
    }

    private static func safeFlashMode(_ mode: String) -> String {
        ["off", "auto", "on"].contains(mode) ? mode : "off"
    }

    private static func safeCaptureRequestType(_ type: String) -> String {
        ["photo", "video_start", "video_stop"].contains(type) ? type : "photo"
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
    case waitingForVideo
    case connected
    case unavailable
    case failed
}

@MainActor
final class WebRtcSessionManager: NSObject, ObservableObject, WebRtcSessionManaging {
    @Published private(set) var state: WebRtcConnectionState = .idle
    @Published private(set) var streamQualityMode: StreamQualityMode = .lowLatency
    @Published private(set) var capturedLensFacing: LensFacing = .back
    @Published private(set) var decodedVideoFrameCount = 0
    @Published private(set) var reconnectCount = 0
    @Published private(set) var iceConnectionStateDescription = "idle"
    #if canImport(WebRTC)
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private var videoSender: RTCRtpSender?
    private var role: WebRtcRole = .host
    private var roomCode: String?
    private var rtcSessionId: String?
    private var repository: (any RoomRepository)?
    private var signalingTask: Task<Void, Never>?
    private var candidatePollingTask: Task<Void, Never>?
    private var videoWatchdogTask: Task<Void, Never>?
    private var capturedLensCommitTask: Task<Void, Never>?
    private var captureSwitchGeneration = 0
    private var appliedRemoteCandidateIDs = Set<String>()
    private var activeCaptureDevice: AVCaptureDevice?
    private var activeLensFacing: LensFacing = .back
    private var activeZoomLevel = 1.0
    private var activeFlashMode = "off"
    private let hostCaptureQueue = DispatchQueue(label: "webrtc.host.capture.queue", qos: .userInitiated)
    private let hostPhotoOutput = AVCapturePhotoOutput()
    private var isHostPhotoOutputPrepared = false
    private let hostVideoFrameOutput = AVCaptureVideoDataOutput()
    private let hostFrameCache = VideoFrameCache()
    private let hostMovieOutput = AVCaptureMovieFileOutput()
    private var pendingHostPhotoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var hostMovieDelegate: MovieCaptureDelegate?
    private var hostRecordingSegments: [URL] = []
    private var hostRecordingCompletion: ((URL?, Error?) -> Void)?
    private var pendingRecordingLensFacing: LensFacing?
    private var shouldFinalizeHostRecording = false
    @Published private(set) var isHostVideoRecording = false
    private var isPreparingHostVideoRecording = false
    private var activeExposureIndex = 0
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
        await startHost(roomCode: roomCode, repository: repository, preserveLocalCapture: false)
    }

    private func startHost(
        roomCode: String,
        repository: any RoomRepository,
        preserveLocalCapture: Bool
    ) async {
        #if canImport(WebRTC)
        let canStart = state == .idle || state == .unavailable || state == .failed || (preserveLocalCapture && state == .connecting)
        guard canStart else { return }
        state = .connecting
        self.role = .host
        self.roomCode = roomCode
        self.repository = repository
        self.rtcSessionId = nil

        do {
            let peerConnection = try makePeerConnection()
            self.peerConnection = peerConnection
            try attachCameraTrack(to: peerConnection, preserveLocalCapture: preserveLocalCapture)
            observeSignaling(roomCode: roomCode, repository: repository)
        } catch {
            state = .failed
        }
        #else
        state = .unavailable
        #endif
    }

    func startController(roomCode: String, repository: any RoomRepository) async {
        await startController(roomCode: roomCode, repository: repository, preserveRemotePreview: false)
    }

    private func startController(
        roomCode: String,
        repository: any RoomRepository,
        preserveRemotePreview: Bool
    ) async {
        #if canImport(WebRTC)
        let canStart = state == .idle || state == .unavailable || state == .failed || (preserveRemotePreview && state == .connecting)
        guard canStart else { return }
        state = .connecting
        self.role = .controller
        self.roomCode = roomCode
        self.repository = repository
        let rtcSessionId = UUID().uuidString
        self.rtcSessionId = rtcSessionId
        if !preserveRemotePreview {
            self.remoteVideoTrack = nil
        }

        do {
            let peerConnection = try makePeerConnection()
            self.peerConnection = peerConnection
            let offer = try await makeOffer(on: peerConnection)
            try await peerConnection.setLocalDescriptionAsync(offer)
            try await repository.setOffer(offer.sdp, roomCode: roomCode, rtcSessionId: rtcSessionId)
            observeSignaling(roomCode: roomCode, repository: repository)
        } catch {
            if !preserveRemotePreview {
                self.remoteVideoTrack = nil
            }
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
        videoWatchdogTask?.cancel()
        videoWatchdogTask = nil
        capturedLensCommitTask?.cancel()
        capturedLensCommitTask = nil
        if hostMovieOutput.isRecording { hostMovieOutput.stopRecording() }
        removeHostMovieOutput()
        cameraCapturer?.stopCapture()
        cameraCapturer = nil
        videoSender = nil
        activeCaptureDevice = nil
        hostMovieDelegate = nil
        hostRecordingSegments.removeAll()
        hostRecordingCompletion = nil
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = false
        isPreparingHostVideoRecording = false
        isHostVideoRecording = false
        pendingHostPhotoDelegates.removeAll()
        activeExposureIndex = 0
        capturedLensFacing = .back
        localVideoTrack = nil
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        #endif
        state = .idle
        iceConnectionStateDescription = "idle"
    }

    func applyStreamQualityMode(_ mode: StreamQualityMode) {
        streamQualityMode = mode
        #if canImport(WebRTC)
        if let videoSender {
            configureVideoSender(videoSender)
        }
        #endif
    }

    func applyCameraControls(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else { return }
        let clampedZoom = max(1.0, min(8.0, zoomLevel))
        let shouldSwitchLens = activeLensFacing != lensFacing
        activeZoomLevel = clampedZoom
        activeFlashMode = flashMode.safeCameraFlashMode

        if shouldSwitchLens {
            guard !isHostVideoRecording, !isPreparingHostVideoRecording else {
                switchRecordingLens(to: lensFacing)
                return
            }
            switchCapture(to: lensFacing)
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
            let targetBias = Float(activeExposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
        #endif
    }

    func applyExposureIndex(_ exposureIndex: Int) {
        #if canImport(WebRTC)
        let clampedIndex = min(8, max(-8, exposureIndex))
        guard activeExposureIndex != clampedIndex else { return }
        activeExposureIndex = clampedIndex
        guard role == .host, let device = activeCaptureDevice else { return }
        applyExposureOnDevice(device, exposureIndex: clampedIndex)
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

    func captureHostPhoto(completion: @escaping (UIImage?, Data?, UIDeviceOrientation, LensFacing, Bool) -> Void) {
        #if canImport(WebRTC)
        guard role == .host, let cameraCapturer else {
            let capturedDeviceOrientation = currentDeviceCaptureOrientation()
            completion(nil, nil, capturedDeviceOrientation, activeLensFacing, shouldUseLandscapeCanvas(photoOutput: hostPhotoOutput, capturedDeviceOrientation: capturedDeviceOrientation))
            return
        }
        let selectedFlashMode = activeFlashMode.safeCameraFlashMode
        let capturedLensFacing = activeLensFacing
        let capturedDeviceOrientation = currentDeviceCaptureOrientation()
        let isPrepared = isHostPhotoOutputPrepared
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed
        let uniqueID = Int64(settings.uniqueID)
        let delegate = PhotoCaptureDelegate { [weak self] image, data, diagnostics in
            Task { @MainActor in
                self?.pendingHostPhotoDelegates[uniqueID] = nil
                let finalUseLandscapeCanvas = diagnostics.storedLandscape
                completion(image, data, capturedDeviceOrientation, capturedLensFacing, finalUseLandscapeCanvas)
            }
        }
        pendingHostPhotoDelegates[uniqueID] = delegate
        let hostPhotoOutput = hostPhotoOutput
        hostCaptureQueue.async { [weak self] in
            let performCapture = {
                if let flashMode = selectedFlashMode.avCaptureFlashMode(supportedModes: hostPhotoOutput.supportedFlashModes) {
                    settings.flashMode = flashMode
                }
                configurePhotoConnection(hostPhotoOutput, lensFacing: capturedLensFacing)
                hostPhotoOutput.capturePhoto(with: settings, delegate: delegate)
            }

            Self.configureHostPhotoOutput(hostPhotoOutput, on: cameraCapturer) {
                if isPrepared {
                    performCapture()
                } else {
                    Self.preparePhotoOutput(hostPhotoOutput) {
                        Task { @MainActor in self?.isHostPhotoOutputPrepared = true }
                        performCapture()
                    }
                }
            }
        }
        #else
        let capturedDeviceOrientation = currentDeviceCaptureOrientation()
        completion(nil, nil, capturedDeviceOrientation, activeLensFacing, shouldUseLandscapeCanvas(photoOutput: hostPhotoOutput, capturedDeviceOrientation: capturedDeviceOrientation))
        #endif
    }

    func startHostVideoRecording(completion: @escaping (URL?, Error?) -> Void) {
        #if canImport(WebRTC)
        guard role == .host, !isHostVideoRecording, !isPreparingHostVideoRecording else { return }
        hostRecordingSegments.removeAll()
        hostRecordingCompletion = completion
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = false
        isHostVideoRecording = true
        startHostRecordingSegment()
        #endif
    }

    func stopHostVideoRecording() {
        #if canImport(WebRTC)
        isPreparingHostVideoRecording = false
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = true
        guard hostMovieOutput.isRecording else {
            finalizeHostRecording(error: nil)
            return
        }
        hostMovieOutput.stopRecording()
        #endif
    }

    func finishHostVideoRecordingBeforeTeardown() async {
        #if canImport(WebRTC)
        guard isHostVideoRecording || isPreparingHostVideoRecording || hostMovieOutput.isRecording else { return }
        await withCheckedContinuation { continuation in
            let existingCompletion = hostRecordingCompletion
            var didResume = false
            hostRecordingCompletion = { url, error in
                existingCompletion?(url, error)
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }
            stopHostVideoRecording()
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
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw WebRtcSessionError.peerConnectionUnavailable
        }
        return peerConnection
    }

    private func attachCameraTrack(to peerConnection: RTCPeerConnection, preserveLocalCapture: Bool) throws {
        if preserveLocalCapture, let localVideoTrack, let cameraCapturer {
            if let sender = peerConnection.add(localVideoTrack, streamIds: ["camera-stream"]) {
                videoSender = sender
                configureVideoSender(sender)
            }
            return
        }

        try startCameraTrack(on: peerConnection)
    }

    private func startCameraTrack(on peerConnection: RTCPeerConnection) throws {
        guard let factory else { throw WebRtcSessionError.factoryUnavailable }
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "camera-video")
        if let sender = peerConnection.add(videoTrack, streamIds: ["camera-stream"]) {
            videoSender = sender
            configureVideoSender(sender)
        }

        cameraCapturer = capturer
        localVideoTrack = videoTrack
        try startCapture(capturer, lensFacing: activeLensFacing)
    }

    private nonisolated static func configurePhotoOutputForSpeed(_ photoOutput: AVCapturePhotoOutput) {
        photoOutput.maxPhotoQualityPrioritization = .speed
        if #available(iOS 17.0, *) {
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = true
            }
        }
    }

    private nonisolated static func preparePhotoOutput(_ photoOutput: AVCapturePhotoOutput, completion: @escaping () -> Void = {}) {
        let supportedFlashModes = photoOutput.supportedFlashModes
        let preparedSettings = [AVCaptureDevice.FlashMode.off, .auto, .on].compactMap { flashMode -> AVCapturePhotoSettings? in
            guard supportedFlashModes.contains(flashMode) else { return nil }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            settings.flashMode = flashMode
            return settings
        }
        let fallbackSettings = AVCapturePhotoSettings()
        fallbackSettings.photoQualityPrioritization = .speed
        photoOutput.setPreparedPhotoSettingsArray(preparedSettings.isEmpty ? [fallbackSettings] : preparedSettings) { _, _ in
            completion()
        }
    }

    private nonisolated static func configureHostPhotoOutput(
        _ photoOutput: AVCapturePhotoOutput,
        on capturer: RTCCameraVideoCapturer,
        completion: @escaping () -> Void = {}
    ) {
        let session = capturer.captureSession
        guard !session.outputs.contains(photoOutput) else {
            completion()
            return
        }
        Self.configurePhotoOutputForSpeed(photoOutput)
        guard session.canAddOutput(photoOutput) else {
            completion()
            return
        }
        session.beginConfiguration()
        session.addOutput(photoOutput)
        session.commitConfiguration()
        Self.preparePhotoOutput(photoOutput, completion: completion)
    }

    private func removeHostPhotoOutput(from capturer: RTCCameraVideoCapturer) {
        let session = capturer.captureSession
        guard session.outputs.contains(hostPhotoOutput) else { return }
        isHostPhotoOutputPrepared = false
        session.beginConfiguration()
        session.removeOutput(hostPhotoOutput)
        session.commitConfiguration()
    }

    private func configureHostVideoFrameOutput(on capturer: RTCCameraVideoCapturer) {
        let session = capturer.captureSession
        guard !session.outputs.contains(hostVideoFrameOutput), session.canAddOutput(hostVideoFrameOutput) else { return }
        hostVideoFrameOutput.alwaysDiscardsLateVideoFrames = true
        hostVideoFrameOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        hostVideoFrameOutput.setSampleBufferDelegate(hostFrameCache, queue: hostFrameCache.queue)
        session.beginConfiguration()
        session.addOutput(hostVideoFrameOutput)
        session.commitConfiguration()
    }

    private func switchRecordingLens(to lensFacing: LensFacing) {
        guard pendingRecordingLensFacing != lensFacing else { return }
        pendingRecordingLensFacing = lensFacing
        guard hostMovieOutput.isRecording else {
            switchCapture(to: lensFacing) { [weak self] in
                self?.startHostRecordingSegment()
            }
            return
        }
        hostMovieOutput.stopRecording()
    }

    private func switchCapture(to lensFacing: LensFacing, completion: (() -> Void)? = nil) {
        guard let cameraCapturer, !isRestartingCapture else { return }
        activeLensFacing = lensFacing
        activeCaptureDevice = nil
        isRestartingCapture = true
        captureSwitchGeneration += 1
        let switchGeneration = captureSwitchGeneration
        var didRestart = false

        func restartIfNeeded() {
            guard !didRestart, captureSwitchGeneration == switchGeneration else { return }
            didRestart = true
            let profile = streamQualityMode.webRtcProfile
            let zoomLevel = activeZoomLevel
            let exposureIndex = activeExposureIndex
            let photoOutput = hostPhotoOutput
            hostCaptureQueue.async { [weak self] in
                do {
                    let device = try Self.startCaptureOnCapturer(cameraCapturer, lensFacing: lensFacing, profile: profile)
                    Self.applyDeviceControls(device, zoomLevel: zoomLevel)
                    Self.applyExposureOnDevice(device, exposureIndex: exposureIndex)
                    Self.configureHostPhotoOutput(photoOutput, on: cameraCapturer) {
                        Task { @MainActor in self?.isHostPhotoOutputPrepared = true }
                    }
                    Task { @MainActor in
                        guard let self, self.captureSwitchGeneration == switchGeneration else { return }
                        self.activeCaptureDevice = device
                        self.activeLensFacing = lensFacing
                        self.isRestartingCapture = false
                        self.capturedLensCommitTask?.cancel()
                        self.capturedLensCommitTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled, self.captureSwitchGeneration == switchGeneration else { return }
                            self.capturedLensFacing = lensFacing
                        }
                        completion?()
                    }
                } catch {
                    Task { @MainActor in
                        guard let self else { return }
                        self.isRestartingCapture = false
                        self.state = .failed
                        self.finalizeHostRecording(error: error)
                    }
                }
            }
        }

        removeHostPhotoOutput(from: cameraCapturer)
        cameraCapturer.stopCapture { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                restartIfNeeded()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard captureSwitchGeneration == switchGeneration, isRestartingCapture else { return }
            restartIfNeeded()
        }
    }

    private func configureHostMovieOutput(on capturer: RTCCameraVideoCapturer) {
        let session = capturer.captureSession
        guard !session.outputs.contains(hostMovieOutput), session.canAddOutput(hostMovieOutput) else { return }
        session.beginConfiguration()
        session.addOutput(hostMovieOutput)
        session.commitConfiguration()
    }

    private func removeHostMovieOutput() {
        guard let cameraCapturer else { return }
        let session = cameraCapturer.captureSession
        guard session.outputs.contains(hostMovieOutput), !hostMovieOutput.isRecording else { return }
        session.beginConfiguration()
        session.removeOutput(hostMovieOutput)
        session.commitConfiguration()
    }

    private func startHostRecordingSegment() {
        guard isHostVideoRecording, !hostMovieOutput.isRecording, !isPreparingHostVideoRecording else { return }
        isPreparingHostVideoRecording = true
        Task { @MainActor in
            do {
                let cameraCapturer = try await readyCameraCapturerForRecording()
                guard isHostVideoRecording, isPreparingHostVideoRecording else { return }
                configureHostMovieOutput(on: cameraCapturer)
                guard hostMovieOutput.connection(with: .video) != nil else {
                    throw WebRtcSessionError.cameraUnavailable
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AI-Camera-\(UUID().uuidString)")
                    .appendingPathExtension("mov")
                let delegate = MovieCaptureDelegate { [weak self] outputURL, error in
                    Task { @MainActor in
                        self?.handleHostRecordingSegmentFinished(outputURL: outputURL, error: error)
                    }
                }
                hostMovieDelegate = delegate
                isPreparingHostVideoRecording = false
                hostMovieOutput.startRecording(to: url, recordingDelegate: delegate)
            } catch {
                isPreparingHostVideoRecording = false
                finalizeHostRecording(error: error)
            }
        }
    }

    private func handleHostRecordingSegmentFinished(outputURL: URL?, error: Error?) {
        hostMovieDelegate = nil
        removeHostMovieOutput()
        if let error {
            finalizeHostRecording(error: error)
            return
        }
        if let outputURL, isUsableRecordingSegment(outputURL) {
            hostRecordingSegments.append(outputURL)
        }
        if let pendingRecordingLensFacing, !shouldFinalizeHostRecording {
            self.pendingRecordingLensFacing = nil
            switchCapture(to: pendingRecordingLensFacing) { [weak self] in
                self?.startHostRecordingSegment()
            }
            return
        }
        if shouldFinalizeHostRecording {
            finalizeHostRecording(error: nil)
        }
    }

    private func finalizeHostRecording(error: Error?) {
        let completion = hostRecordingCompletion
        let segments = hostRecordingSegments
        hostRecordingCompletion = nil
        hostRecordingSegments.removeAll()
        pendingRecordingLensFacing = nil
        shouldFinalizeHostRecording = false
        isPreparingHostVideoRecording = false
        isHostVideoRecording = false

        if let error {
            completion?(nil, error)
            return
        }
        guard let completion else { return }
        if segments.count <= 1 {
            completion(segments.first, nil)
            return
        }
        Task {
            do {
                let mergedURL = try await mergeRecordingSegments(segments)
                await MainActor.run { completion(mergedURL, nil) }
            } catch {
                await MainActor.run {
                    segments.forEach { completion($0, nil) }
                }
            }
        }
    }

    private func isUsableRecordingSegment(_ url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    private func mergeRecordingSegments(_ segments: [URL]) async throws -> URL {
        struct SegmentInfo {
            let asset: AVURLAsset
            let videoTrack: AVAssetTrack
            let audioTrack: AVAssetTrack?
            let duration: CMTime
            let naturalSize: CGSize
            let preferredTransform: CGAffineTransform
            let orientedRect: CGRect
        }

        var segmentInfos: [SegmentInfo] = []
        var renderSize = CGSize.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else { continue }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
            renderSize.width = max(renderSize.width, abs(orientedRect.width))
            renderSize.height = max(renderSize.height, abs(orientedRect.height))
            segmentInfos.append(SegmentInfo(
                asset: asset,
                videoTrack: sourceVideo,
                audioTrack: sourceAudio,
                duration: duration,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                orientedRect: orientedRect
            ))
        }
        guard !segmentInfos.isEmpty, renderSize != .zero else { throw WebRtcSessionError.cameraUnavailable }
        renderSize.width = ceil(renderSize.width / 2.0) * 2.0
        renderSize.height = ceil(renderSize.height / 2.0) * 2.0

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for info in segmentInfos {
            guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw WebRtcSessionError.cameraUnavailable
            }
            let timeRange = CMTimeRange(start: .zero, duration: info.duration)
            try compositionVideoTrack.insertTimeRange(timeRange, of: info.videoTrack, at: cursor)
            if let sourceAudio = info.audioTrack,
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: info.duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            let positiveSpaceTransform = info.preferredTransform.concatenating(
                CGAffineTransform(translationX: -info.orientedRect.minX, y: -info.orientedRect.minY)
            )
            let centeredTransform = positiveSpaceTransform.concatenating(
                CGAffineTransform(
                    translationX: (renderSize.width - abs(info.orientedRect.width)) / 2.0,
                    y: (renderSize.height - abs(info.orientedRect.height)) / 2.0
                )
            )
            layerInstruction.setTransform(centeredTransform, at: cursor)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
            cursor = cursor + info.duration
        }
        guard cursor.seconds > 0 else { throw WebRtcSessionError.cameraUnavailable }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AI-Camera-Merged-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality) else {
            throw WebRtcSessionError.cameraUnavailable
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                if let error = exportSession.error {
                    continuation.resume(throwing: error)
                } else if exportSession.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WebRtcSessionError.cameraUnavailable)
                }
            }
        }
        segments.forEach { try? FileManager.default.removeItem(at: $0) }
        return outputURL
    }

    private func readyCameraCapturerForRecording() async throws -> RTCCameraVideoCapturer {
        for _ in 0..<18 {
            if let cameraCapturer,
               !isRestartingCapture,
               activeCaptureDevice != nil,
               cameraCapturer.captureSession.isRunning {
                return cameraCapturer
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw WebRtcSessionError.cameraUnavailable
    }

    private func startCapture(
        _ capturer: RTCCameraVideoCapturer,
        lensFacing: LensFacing,
        commitCapturedLensImmediately: Bool = true
    ) throws {
        let device = try Self.startCaptureOnCapturer(capturer, lensFacing: lensFacing, profile: streamQualityMode.webRtcProfile)
        activeCaptureDevice = device
        activeLensFacing = lensFacing
        if commitCapturedLensImmediately {
            capturedLensFacing = lensFacing
        }
        applyDeviceControls(zoomLevel: activeZoomLevel)
        applyExposureOnDevice(device, exposureIndex: activeExposureIndex)
        isHostPhotoOutputPrepared = false
        Self.configureHostPhotoOutput(hostPhotoOutput, on: capturer) { [weak self] in
            Task { @MainActor in self?.isHostPhotoOutputPrepared = true }
        }
    }

    private nonisolated static func startCaptureOnCapturer(
        _ capturer: RTCCameraVideoCapturer,
        lensFacing: LensFacing,
        profile: WebRtcStreamProfile
    ) throws -> AVCaptureDevice {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let position: AVCaptureDevice.Position = lensFacing == .back ? .back : .front
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let preferredFormats = formats.sorted { lhs, rhs in
            let lhsSize = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsSize = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsDistance = abs(Int(lhsSize.width) - profile.width) + abs(Int(lhsSize.height) - profile.height)
            let rhsDistance = abs(Int(rhsSize.width) - profile.width) + abs(Int(rhsSize.height) - profile.height)
            return lhsDistance < rhsDistance
        }
        guard let format = preferredFormats.first else {
            throw WebRtcSessionError.cameraUnavailable
        }
        let supportedFPS = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max() ?? profile.fps
        capturer.startCapture(with: device, format: format, fps: min(supportedFPS, profile.fps))
        return device
    }

    private nonisolated static func applyDeviceControls(_ device: AVCaptureDevice, zoomLevel: Double) {
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(maxZoom, zoomLevel))
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private nonisolated static func applyExposureOnDevice(_ device: AVCaptureDevice, exposureIndex: Int) {
        do {
            try device.lockForConfiguration()
            let targetBias = Float(exposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias) { _ in }
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
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

    private func applyExposureOnDevice(_ device: AVCaptureDevice, exposureIndex: Int) {
        do {
            try device.lockForConfiguration()
            let targetBias = Float(exposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }

    private func configureVideoSender(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        let profile = streamQualityMode.webRtcProfile
        parameters.encodings.forEach { encoding in
            encoding.minBitrateBps = NSNumber(value: profile.minBitrate)
            encoding.maxBitrateBps = NSNumber(value: profile.maxBitrate)
            encoding.maxFramerate = NSNumber(value: profile.fps)
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
            var pollCount = 0
            while !Task.isCancelled {
                await self.applyRemoteCandidates(roomCode: roomCode, repository: repository)
                pollCount += 1
                let delay: Duration
                if pollCount < 80 {
                    delay = .milliseconds(150)
                } else if pollCount < 180 {
                    delay = .milliseconds(500)
                } else {
                    delay = .seconds(2)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func apply(room: RoomDocument, repository: any RoomRepository) async {
        guard let peerConnection else { return }
        do {
            if role == .host,
               let roomRtcSessionId = room.rtcSessionId,
               let currentSessionId = rtcSessionId,
               roomRtcSessionId != currentSessionId,
               peerConnection.remoteDescription != nil {
                await restartHost(roomCode: room.roomCode, repository: repository)
                return
            }

            if rtcSessionId == nil, let roomRtcSessionId = room.rtcSessionId {
                rtcSessionId = roomRtcSessionId
            }

            if role == .host, room.controllerApproved, peerConnection.remoteDescription == nil, let offerSdp = room.offer {
                try await peerConnection.setRemoteDescriptionAsync(RTCSessionDescription(type: .offer, sdp: offerSdp))
                let answer = try await makeAnswer(on: peerConnection)
                try await peerConnection.setLocalDescriptionAsync(answer)
                let activeSessionId = room.rtcSessionId ?? rtcSessionId ?? UUID().uuidString
                rtcSessionId = activeSessionId
                try await repository.setAnswer(answer.sdp, roomCode: room.roomCode, rtcSessionId: activeSessionId)
                state = .waitingForVideo
            }

            if role == .controller, peerConnection.remoteDescription == nil, let answerSdp = room.answer {
                try await peerConnection.setRemoteDescriptionAsync(RTCSessionDescription(type: .answer, sdp: answerSdp))
                state = remoteVideoTrack == nil ? .waitingForVideo : .connected
            }
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

    private func startVideoWatchdog() {
        guard role == .controller else { return }
        videoWatchdogTask?.cancel()
        videoWatchdogTask = Task { [weak self] in
            var lastDecodedFrames = -1
            var stalledChecks = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.role == .controller, self.state == .connected else { continue }
                guard let decodedFrames = await self.decodedVideoFrames() else { continue }

                if lastDecodedFrames >= 0, decodedFrames <= lastDecodedFrames {
                    stalledChecks += 1
                } else {
                    stalledChecks = 0
                    lastDecodedFrames = decodedFrames
                    self.decodedVideoFrameCount = decodedFrames
                }

                if stalledChecks >= 4, let roomCode = self.roomCode, let repository = self.repository {
                    await self.restartController(roomCode: roomCode, repository: repository)
                    return
                }
            }
        }
    }

    func retryControllerConnection(roomCode: String, repository: any RoomRepository) async {
        #if canImport(WebRTC)
        guard role == .controller else { return }
        await restartController(roomCode: roomCode, repository: repository)
        #endif
    }

    private func restartController(roomCode: String, repository: any RoomRepository) async {
        reconnectCount += 1
        prepareControllerReconnect()
        try? await Task.sleep(for: .milliseconds(150))
        await startController(roomCode: roomCode, repository: repository, preserveRemotePreview: true)
    }

    private func prepareControllerReconnect() {
        #if canImport(WebRTC)
        signalingTask?.cancel()
        signalingTask = nil
        candidatePollingTask?.cancel()
        candidatePollingTask = nil
        videoWatchdogTask?.cancel()
        videoWatchdogTask = nil
        peerConnection?.close()
        peerConnection = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        state = .connecting
        iceConnectionStateDescription = "reconnecting"
        #endif
    }

    private func restartHost(roomCode: String, repository: any RoomRepository) async {
        reconnectCount += 1
        prepareHostReconnect()
        try? await Task.sleep(for: .milliseconds(100))
        await startHost(roomCode: roomCode, repository: repository, preserveLocalCapture: true)
    }

    private func prepareHostReconnect() {
        #if canImport(WebRTC)
        signalingTask?.cancel()
        signalingTask = nil
        candidatePollingTask?.cancel()
        candidatePollingTask = nil
        videoWatchdogTask?.cancel()
        videoWatchdogTask = nil
        peerConnection?.close()
        peerConnection = nil
        videoSender = nil
        appliedRemoteCandidateIDs.removeAll()
        rtcSessionId = nil
        state = .connecting
        iceConnectionStateDescription = "reconnecting"
        #endif
    }

    private func decodedVideoFrames() async -> Int? {
        guard let peerConnection else { return nil }
        return await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                let framesDecoded = report.statistics.values.compactMap { statistic -> Int? in
                    guard statistic.type == "inbound-rtp" else { return nil }
                    guard (statistic.values["kind"] as? String == "video") || (statistic.values["mediaType"] as? String == "video") else { return nil }
                    if let value = statistic.values["framesDecoded"] as? NSNumber {
                        return value.intValue
                    }
                    if let value = statistic.values["framesReceived"] as? NSNumber {
                        return value.intValue
                    }
                    return nil
                }.max()
                continuation.resume(returning: framesDecoded)
            }
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
private struct WebRtcStreamProfile {
    let width: Int
    let height: Int
    let fps: Int
    let minBitrate: Int
    let maxBitrate: Int
}

private extension StreamQualityMode {
    var webRtcProfile: WebRtcStreamProfile {
        switch self {
        case .lowLatency:
            return WebRtcStreamProfile(width: 640, height: 360, fps: 20, minBitrate: 300_000, maxBitrate: 900_000)
        case .balanced:
            return WebRtcStreamProfile(width: 854, height: 480, fps: 20, minBitrate: 500_000, maxBitrate: 1_400_000)
        case .quality:
            return WebRtcStreamProfile(width: 1280, height: 720, fps: 20, minBitrate: 900_000, maxBitrate: 2_400_000)
        }
    }
}

private extension RTCIceConnectionState {
    var diagnosticDescription: String {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }
}

extension WebRtcSessionManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            Task { @MainActor in
                self.remoteVideoTrack = track
                self.state = .connected
                self.startVideoWatchdog()
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in self.iceConnectionStateDescription = newState.diagnosticDescription }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            Task { @MainActor in
                self.remoteVideoTrack = track
                self.state = .connected
                self.startVideoWatchdog()
            }
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
    @Published var flashMode = "off"

    var flashEnabled: Bool { flashMode != "off" }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private var isPhotoOutputPrepared = false
    private var currentInput: AVCaptureDeviceInput?
    private var pendingPhotoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private let photoSaving: any PhotoSaving
    private var didPrewarmPhotoStorage = false

    override convenience init() {
        self.init(photoSaving: PhotoLibrarySavingService())
    }

    init(photoSaving: any PhotoSaving) {
        self.photoSaving = photoSaving
        super.init()
        permissionState = Self.currentPermissionState()
    }

    func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
            configureAndStart()
            prewarmPhotoStorageIfNeeded()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
            if granted {
                configureAndStart()
                prewarmPhotoStorageIfNeeded()
            }
        default:
            permissionState = .denied
        }
    }

    func prepareForPhotoCapture(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) async -> Bool {
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
        self.flashMode = flashMode.safeCameraFlashMode
        return await configureAndStartForPhotoCapture()
    }

    func stop() {
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    func stopAndWait() async {
        let session = session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
                Task { @MainActor in self.isRunning = false }
                continuation.resume()
            }
        }
    }

    func stopAndReleaseCamera() async {
        let session = session
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                if let currentInput = self.currentInput {
                    session.removeInput(currentInput)
                    self.currentInput = nil
                }
                session.commitConfiguration()
                Task { @MainActor in self.isRunning = false }
                continuation.resume()
            }
        }
    }

    func apply(lensFacing: LensFacing, zoomLevel: Double, flashMode: String) {
        let clampedZoom = max(1.0, min(8.0, zoomLevel))
        let shouldSwitchLens = self.lensFacing != lensFacing
        self.lensFacing = lensFacing
        self.zoomLevel = clampedZoom
        self.flashMode = flashMode.safeCameraFlashMode
        shouldSwitchLens ? configureAndStart() : applyZoom(clampedZoom)
    }

    func applyExposureIndex(_ exposureIndex: Int) {
        let clampedIndex = min(8, max(-8, exposureIndex))
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyExposureOnQueue(clampedIndex, device: device)
        }
    }

    func switchLens() {
        apply(lensFacing: lensFacing == .back ? .front : .back, zoomLevel: zoomLevel, flashMode: flashMode)
    }

    private func prewarmPhotoStorageIfNeeded() {
        guard !didPrewarmPhotoStorage else { return }
        didPrewarmPhotoStorage = true
        Task { [photoSaving] in
            await photoSaving.prewarm()
        }
    }

    private nonisolated static func configurePhotoOutputForSpeed(_ photoOutput: AVCapturePhotoOutput) {
        photoOutput.maxPhotoQualityPrioritization = .speed
        if #available(iOS 17.0, *) {
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
            }
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = true
            }
        }
    }

    private nonisolated static func preparePhotoOutput(_ photoOutput: AVCapturePhotoOutput, completion: @escaping () -> Void = {}) {
        let supportedFlashModes = photoOutput.supportedFlashModes
        let preparedSettings = [AVCaptureDevice.FlashMode.off, .auto, .on].compactMap { flashMode -> AVCapturePhotoSettings? in
            guard supportedFlashModes.contains(flashMode) else { return nil }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            settings.flashMode = flashMode
            return settings
        }
        let fallbackSettings = AVCapturePhotoSettings()
        fallbackSettings.photoQualityPrioritization = .speed
        photoOutput.setPreparedPhotoSettingsArray(preparedSettings.isEmpty ? [fallbackSettings] : preparedSettings) { _, _ in
            completion()
        }
    }

    func saveCapturedPhotoFromStream(_ image: UIImage?, data: Data?, capturedDeviceOrientation: UIDeviceOrientation, lensFacing: LensFacing, useLandscapeCanvas: Bool) async {
        lastCapturedImage = image
        await saveCapturedPhoto(image, data: data)
    }

    func saveCapturedVideoFromStream(_ url: URL?, error: Error?) async {
        guard error == nil, let url else {
            photoSaveMessage = "Video recording failed."
            return
        }
        let outcome = await photoSaving.saveVideo(at: url)
        lastSavedPhotoURL = outcome.localURL
        photoSaveMessage = outcome.message
    }

    func capturePhoto(completion: ((UIImage?) -> Void)? = nil) {
        let selectedFlashMode = flashMode.safeCameraFlashMode
        let capturedLensFacing = lensFacing
        let photoOutput = photoOutput
        let isPrepared = isPhotoOutputPrepared
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed
        let uniqueID = Int64(settings.uniqueID)
        let delegate = PhotoCaptureDelegate { [weak self] image, data, _ in
            Task { @MainActor in
                self?.lastCapturedImage = image
                self?.pendingPhotoDelegates[uniqueID] = nil
                completion?(image)
                Task { @MainActor in
                    await self?.saveCapturedPhoto(image, data: data)
                }
            }
        }
        pendingPhotoDelegates[uniqueID] = delegate
        sessionQueue.async { [weak self] in
            let performCapture = {
                if let flashMode = selectedFlashMode.avCaptureFlashMode(supportedModes: photoOutput.supportedFlashModes) {
                    settings.flashMode = flashMode
                }
                configurePhotoConnection(photoOutput, lensFacing: capturedLensFacing)
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }

            if isPrepared {
                performCapture()
            } else {
                Self.preparePhotoOutput(photoOutput) {
                    Task { @MainActor in self?.isPhotoOutputPrepared = true }
                    performCapture()
                }
            }
        }
    }

    private func configureAndStart() {
        isPhotoOutputPrepared = false
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
                if !session.outputs.contains(photoOutput) {
                    Self.configurePhotoOutputForSpeed(photoOutput)
                    if session.canAddOutput(photoOutput) {
                        session.addOutput(photoOutput)
                    }
                }
                session.commitConfiguration()
                Self.preparePhotoOutput(photoOutput) {
                    Task { @MainActor in self.isPhotoOutputPrepared = true }
                }
                self.applyZoomOnQueue(selectedZoom, device: device)
                self.applyExposureOnQueue(0, device: device)
                if !session.isRunning { session.startRunning() }
                Task { @MainActor in self.isRunning = session.isRunning }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in self.permissionState = .denied }
            }
        }
    }

    private func configureAndStartForPhotoCapture() async -> Bool {
        isPhotoOutputPrepared = false
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
                    if !session.outputs.contains(photoOutput) {
                        Self.configurePhotoOutputForSpeed(photoOutput)
                        if session.canAddOutput(photoOutput) {
                            session.addOutput(photoOutput)
                        }
                    }
                    session.commitConfiguration()
                    Self.preparePhotoOutput(photoOutput) {
                        Task { @MainActor in self.isPhotoOutputPrepared = true }
                    }
                    self.applyZoomOnQueue(selectedZoom, device: device)
                    self.applyExposureOnQueue(0, device: device)
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

    private func applyExposureOnQueue(_ exposureIndex: Int, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let targetBias = Float(exposureIndex) / 2.0
            let clampedBias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, targetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
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

    private func saveCapturedPhoto(_ image: UIImage?, data originalData: Data?) async {
        if let image {
            lastCapturedImage = image
        }
        guard let originalData else {
            photoSaveMessage = "Capture failed. Original photo data was unavailable."
            return
        }

        let outcome = await photoSaving.savePhoto(originalData)
        lastSavedPhotoURL = outcome.localURL
        photoSaveMessage = outcome.message
    }
}

private func configurePhotoConnection(_ photoOutput: AVCapturePhotoOutput, lensFacing: LensFacing) {
    guard let connection = photoOutput.connection(with: .video) else { return }
    if connection.isVideoOrientationSupported {
        connection.videoOrientation = currentCaptureVideoOrientation()
    }
    if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = lensFacing == .front
    }
}

private func currentCaptureVideoOrientation() -> AVCaptureVideoOrientation {
    switch currentDeviceCaptureOrientation() {
    case .landscapeLeft:
        return .landscapeRight
    case .landscapeRight:
        return .landscapeLeft
    case .portraitUpsideDown:
        return .portraitUpsideDown
    default:
        return .portrait
    }
}

private func shouldUseLandscapeCanvas(photoOutput: AVCapturePhotoOutput, capturedDeviceOrientation: UIDeviceOrientation) -> Bool {
    capturedDeviceOrientation.isLandscape
        || photoOutput.connection(with: .video)?.videoOrientation.isLandscapeCapture == true
        || currentInterfaceCaptureOrientation()?.isLandscape == true
}

private func currentDeviceCaptureOrientation() -> UIDeviceOrientation {
    DeviceOrientationTracker.shared.currentOrientation()
}

private func currentInterfaceCaptureOrientation() -> UIDeviceOrientation? {
    let orientation = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .interfaceOrientation

    switch orientation {
    case .landscapeLeft:
        return .landscapeLeft
    case .landscapeRight:
        return .landscapeRight
    case .portrait:
        return .portrait
    case .portraitUpsideDown:
        return .portraitUpsideDown
    default:
        return nil
    }
}

private extension AVCaptureVideoOrientation {
    var isLandscapeCapture: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }
}

private final class DeviceOrientationTracker: NSObject {
    static let shared = DeviceOrientationTracker()

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let lock = NSLock()
    private var lastValidOrientation: UIDeviceOrientation = .portrait
    private var hasMotionOrientation = false

    private override init() {
        super.init()
        motionQueue.name = "camera.orientation.tracker.queue"
        motionQueue.qualityOfService = .utility
        motionQueue.maxConcurrentOperationCount = 1
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateOrientation(UIDevice.current.orientation)
        startMotionUpdates()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    func currentOrientation() -> UIDeviceOrientation {
        lock.lock()
        let shouldUseDeviceOrientation = !hasMotionOrientation
        let orientation = lastValidOrientation
        lock.unlock()

        if shouldUseDeviceOrientation {
            updateOrientation(UIDevice.current.orientation)
            lock.lock()
            let updatedOrientation = lastValidOrientation
            lock.unlock()
            return updatedOrientation
        }
        return orientation
    }

    @objc private func deviceOrientationDidChange() {
        lock.lock()
        let shouldUseDeviceOrientation = !hasMotionOrientation
        lock.unlock()
        guard shouldUseDeviceOrientation else { return }
        updateOrientation(UIDevice.current.orientation)
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.25
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            self.updateOrientationFromGravity(x: gravity.x, y: gravity.y)
        }
    }

    private func updateOrientationFromGravity(x: Double, y: Double) {
        let horizontalMagnitude = abs(x)
        let verticalMagnitude = abs(y)
        guard max(horizontalMagnitude, verticalMagnitude) > 0.45 else { return }
        let orientation: UIDeviceOrientation = if horizontalMagnitude > verticalMagnitude {
            x > 0 ? .landscapeRight : .landscapeLeft
        } else {
            y > 0 ? .portraitUpsideDown : .portrait
        }
        lock.lock()
        hasMotionOrientation = true
        lastValidOrientation = orientation
        lock.unlock()
    }

    private func updateOrientation(_ orientation: UIDeviceOrientation) {
        guard orientation.isLandscape || orientation.isPortrait else { return }
        lock.lock()
        lastValidOrientation = orientation
        lock.unlock()
    }
}

private final class VideoFrameCache: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "camera.video.frame.cache.queue")

    private let context = CIContext()
    private let lock = NSLock()
    private var cgImage: CGImage?

    @MainActor
    func latestImage(lensFacing: LensFacing) -> UIImage? {
        lock.lock()
        let image = cgImage
        lock.unlock()
        guard let image else { return nil }
        return UIImage(cgImage: image, scale: 1.0, orientation: Self.imageOrientation(lensFacing: lensFacing))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        lock.lock()
        cgImage = image
        lock.unlock()
    }

    @MainActor
    private static func imageOrientation(lensFacing: LensFacing) -> UIImage.Orientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return lensFacing == .front ? .downMirrored : .up
        case .landscapeRight:
            return lensFacing == .front ? .upMirrored : .down
        case .portraitUpsideDown:
            return lensFacing == .front ? .rightMirrored : .left
        default:
            return lensFacing == .front ? .leftMirrored : .right
        }
    }
}

private struct PhotoCaptureDiagnostics {
    let photoWidth: Int32
    let photoHeight: Int32
    let metadataOrientation: UInt32?
    let imageOrientation: UIImage.Orientation?
    let storedLandscape: Bool
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?, Data?, PhotoCaptureDiagnostics) -> Void

    init(completion: @escaping (UIImage?, Data?, PhotoCaptureDiagnostics) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            completion(nil, nil, PhotoCaptureDiagnostics(
                photoWidth: 0,
                photoHeight: 0,
                metadataOrientation: nil,
                imageOrientation: nil,
                storedLandscape: false
            ))
            return
        }
        let diagnostics = Self.diagnostics(for: photo)
        completion(nil, data, diagnostics)
    }

    private static func diagnostics(for photo: AVCapturePhoto) -> PhotoCaptureDiagnostics {
        let dimensions = photo.resolvedSettings.photoDimensions
        let orientationValue = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32
        return PhotoCaptureDiagnostics(
            photoWidth: dimensions.width,
            photoHeight: dimensions.height,
            metadataOrientation: orientationValue,
            imageOrientation: nil,
            storedLandscape: isStoredLandscape(width: dimensions.width, height: dimensions.height, orientationValue: orientationValue)
        )
    }

    private static func isStoredLandscape(width: Int32, height: Int32, orientationValue: UInt32?) -> Bool {
        guard width > height else { return false }
        guard let orientation = orientationValue.flatMap(CGImagePropertyOrientation.init(rawValue:)) else {
            return true
        }
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return false
        default:
            return true
        }
    }
}

private final class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let completion: (URL?, Error?) -> Void

    init(completion: @escaping (URL?, Error?) -> Void) {
        self.completion = completion
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        completion(error == nil ? outputFileURL : nil, error)
    }
}

struct ContentView: View {
    @StateObject private var services = AppServices()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            HomeScreen(path: $path)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .cameraHost(let roomCode):
                        CameraHostScreen(roomCode: roomCode, path: $path)
                    case .controllerEntry:
                        ControllerEntryScreen(path: $path)
                    case .waitingForApproval(let roomCode):
                        WaitingForApprovalScreen(roomCode: roomCode, path: $path)
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
    @Binding var path: NavigationPath

    @EnvironmentObject private var services: AppServices
    @StateObject private var camera = CameraController()
    @State private var room: RoomDocument?
    @State private var errorMessage: String?
    @State private var lastHandledCaptureRequestId: String?
    @State private var isHandlingRemoteCapture = false
    @State private var lastHandledFocusRequestId = 0
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
                        .blur(radius: isSwitchingLens ? 16 : 0)
                        .saturation(isSwitchingLens ? 0.65 : 1)
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
                    services.webRtcSession.captureHostPhoto { image, data, capturedDeviceOrientation, lensFacing, useLandscapeCanvas in
                        Task {
                            await camera.saveCapturedPhotoFromStream(
                                image,
                                data: data,
                                capturedDeviceOrientation: capturedDeviceOrientation,
                                lensFacing: lensFacing,
                                useLandscapeCanvas: useLandscapeCanvas
                            )
                        }
                        isHandlingRemoteCapture = false
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

    private func updateAspectRatioMode(_ mode: String) {
        Task { try? await services.roomRepository.updateAspectRatioMode(roomCode: roomCode, aspectRatioMode: mode) }
    }
}

private struct CameraSwitchingOverlay: View {
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
                            .blur(radius: isSwitchingLens ? 16 : 0)
                            .saturation(isSwitchingLens ? 0.65 : 1)
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
                .aspectRatio((room?.aspectRatioMode ?? "full").cameraPreviewAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
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
            zoomStrip

            HStack {
                Spacer()
                shutterButton
                Spacer()
            }

            HStack(spacing: 18) {
                modeButton("video", label: "Video")
                modeButton("photo", label: "Photo")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.42), in: Capsule())

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
                    requestId: Int(Date().timeIntervalSince1970 * 1000),
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
