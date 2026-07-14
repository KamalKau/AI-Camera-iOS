import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
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
            room.captureRequestId = 0
            room.captureRequestType = "photo"
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
            room.captureRequest = nil
            room.captureRequestId = 0
            room.captureRequestType = "photo"
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

    func updateLensFacing(roomCode: String, lensFacing: LensFacing) async throws {
        try update(roomCode: roomCode) { $0.lensFacing = lensFacing }
    }

    func updateZoomLevel(roomCode: String, zoomLevel: Double) async throws {
        try update(roomCode: roomCode) { room in
            room.zoomLevel = max(room.minZoom, min(room.maxZoom, zoomLevel))
        }
    }

    func updateZoomRange(roomCode: String, minZoom: Double, maxZoom: Double) async throws {
        try update(roomCode: roomCode) { room in
            room.minZoom = max(1.0, minZoom)
            room.maxZoom = max(room.minZoom, maxZoom)
            room.zoomLevel = max(room.minZoom, min(room.maxZoom, room.zoomLevel))
        }
    }

    func updateFlashMode(roomCode: String, flashMode: String) async throws {
        let safeFlashMode = Self.safeFlashMode(flashMode)
        try update(roomCode: roomCode) { room in
            room.flashMode = safeFlashMode
            room.flashEnabled = safeFlashMode != "off"
        }
    }

    func updateCameraMode(roomCode: String, cameraMode: String) async throws {
        try update(roomCode: roomCode) { $0.cameraMode = Self.safeCameraMode(cameraMode) }
    }

    func updateGridEnabled(roomCode: String, gridEnabled: Bool) async throws {
        try update(roomCode: roomCode) { $0.gridEnabled = gridEnabled }
    }

    func updateNightModeEnabled(roomCode: String, nightModeEnabled: Bool) async throws {
        try update(roomCode: roomCode) { $0.nightModeEnabled = nightModeEnabled }
    }

    func updateVideoHdrEnabled(roomCode: String, videoHdrEnabled: Bool) async throws {
        try update(roomCode: roomCode) { $0.videoHdrEnabled = videoHdrEnabled }
    }

    func updateToolbarExpanded(roomCode: String, toolbarExpanded: Bool) async throws {
        try update(roomCode: roomCode) { $0.toolbarExpanded = toolbarExpanded }
    }

    func updatePortraitControls(roomCode: String, blurLevel: String, strength: Int, effect: String) async throws {
        try update(roomCode: roomCode) { room in
            room.portraitBlurLevel = Self.safePortraitEffect(blurLevel)
            room.portraitStrength = Self.safePortraitStrength(strength)
            room.portraitEffect = Self.safePortraitEffect(effect)
        }
    }

    func updatePortraitSubjectState(roomCode: String, state: PortraitSubjectState) async throws {
        try update(roomCode: roomCode) { room in
            room.portraitStatus = state.status
            room.portraitFaceLeft = Self.clampedUnit(state.faceBounds.left)
            room.portraitFaceTop = Self.clampedUnit(state.faceBounds.top)
            room.portraitFaceRight = Self.clampedUnit(state.faceBounds.right)
            room.portraitFaceBottom = Self.clampedUnit(state.faceBounds.bottom)
        }
    }

    func updateFaceDetectionOverlay(roomCode: String, state: FaceDetectionOverlayState) async throws {
        try update(roomCode: roomCode) { room in
            room.faceDetected = state.detected
            room.faceCount = max(0, state.count)
            room.faceDetectionTimestamp = state.timestamp
            room.faceBox = Self.clampedBounds(state.primaryBox)
            room.faceBoxes = state.boxes.map(Self.clampedBounds)
        }
    }

    func updateSceneDetectionEnabled(roomCode: String, sceneDetectionEnabled: Bool) async throws {
        try update(roomCode: roomCode) { $0.sceneDetectionEnabled = sceneDetectionEnabled }
    }

    func updateSceneDetectionState(roomCode: String, state: SceneDetectionState) async throws {
        try update(roomCode: roomCode) { room in
            room.sceneDetection = state
        }
    }

    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws {
        try update(roomCode: roomCode) { $0.aspectRatioMode = Self.safeAspectRatioMode(aspectRatioMode) }
    }

    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int64, lockEnabled: Bool) async throws {
        try update(roomCode: roomCode) { room in
            room.focusPointX = min(1.0, max(0.0, x))
            room.focusPointY = min(1.0, max(0.0, y))
            room.focusRequestId = requestId
            room.focusLockEnabled = lockEnabled
        }
    }

    func updateExposureState(roomCode: String, state: ExposureState) async throws {
        try update(roomCode: roomCode) { room in
            room.exposureMinIndex = state.minIndex
            room.exposureMaxIndex = max(state.minIndex, state.maxIndex)
            room.exposureIndex = min(room.exposureMaxIndex, max(room.exposureMinIndex, state.currentIndex))
        }
    }

    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws {
        try update(roomCode: roomCode) { room in
            room.exposureIndex = min(room.exposureMaxIndex, max(room.exposureMinIndex, exposureIndex))
        }
    }

    func updateFlashSupported(roomCode: String, flashSupported: Bool) async throws {
        try update(roomCode: roomCode) { room in
            room.flashSupported = flashSupported
            if !flashSupported {
                room.flashEnabled = false
                room.flashMode = "off"
            }
        }
    }

    func updatePreviewSize(roomCode: String, width: Int, height: Int) async throws {
        try update(roomCode: roomCode) { room in
            room.previewWidth = max(0, width)
            room.previewHeight = max(0, height)
        }
    }

    func requestCapture(roomCode: String, type: String) async throws {
        try update(roomCode: roomCode) { room in
            let request = CaptureRequest.new(type: Self.safeCaptureRequestType(type))
            room.captureRequest = request
            room.captureRequestId = request.id
            room.captureRequestType = request.type
        }
    }

    func resetCaptureRequest(roomCode: String) async throws {
        try update(roomCode: roomCode) { room in
            room.captureRequest = nil
            room.captureRequestId = 0
            room.captureRequestType = "photo"
        }
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

    func clearIceCandidates(roomCode: String) async throws {
        try update(roomCode: roomCode) { room in
            room.cameraCandidates = []
            room.controllerCandidates = []
        }
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
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<5).compactMap { _ in chars.randomElement() })
    }

    private nonisolated static func safeAspectRatioMode(_ mode: String) -> String {
        RoomSchema.safeAspectRatioMode(mode)
    }

    private nonisolated static func safeCameraMode(_ mode: String) -> String {
        RoomSchema.safeCameraMode(mode)
    }

    private nonisolated static func safeFlashMode(_ mode: String) -> String {
        RoomSchema.safeFlashMode(mode)
    }

    private nonisolated static func safeCaptureRequestType(_ type: String) -> String {
        RoomSchema.safeCaptureRequestType(type)
    }

    private nonisolated static func safePortraitEffect(_ effect: String) -> String {
        RoomSchema.safePortraitEffect(effect)
    }

    private nonisolated static func safePortraitStrength(_ strength: Int) -> Int {
        RoomSchema.safePortraitStrength(strength)
    }

    private nonisolated static func clampedUnit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private nonisolated static func clampedBounds(_ bounds: NormalizedFaceBounds) -> NormalizedFaceBounds {
        NormalizedFaceBounds(
            left: clampedUnit(bounds.left),
            top: clampedUnit(bounds.top),
            right: clampedUnit(bounds.right),
            bottom: clampedUnit(bounds.bottom)
        )
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
            "captureRequest": false,
            "captureRequestId": 0,
            "captureRequestType": "photo",
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

    func updateLensFacing(roomCode: String, lensFacing: LensFacing) async throws {
        try await update(roomCode: roomCode, values: ["lensFacing": lensFacing.rawValue])
    }

    func updateZoomLevel(roomCode: String, zoomLevel: Double) async throws {
        try await update(roomCode: roomCode, values: ["zoomLevel": max(1.0, min(8.0, zoomLevel))])
    }

    func updateZoomRange(roomCode: String, minZoom: Double, maxZoom: Double) async throws {
        let safeMinZoom = max(1.0, minZoom)
        try await update(roomCode: roomCode, values: [
            "minZoom": safeMinZoom,
            "maxZoom": max(safeMinZoom, maxZoom)
        ])
    }

    func updateFlashMode(roomCode: String, flashMode: String) async throws {
        let safeFlashMode = Self.safeFlashMode(flashMode)
        try await update(roomCode: roomCode, values: [
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

    func updateNightModeEnabled(roomCode: String, nightModeEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["nightModeEnabled": nightModeEnabled])
    }

    func updateVideoHdrEnabled(roomCode: String, videoHdrEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["videoHdrEnabled": videoHdrEnabled])
    }

    func updateToolbarExpanded(roomCode: String, toolbarExpanded: Bool) async throws {
        try await update(roomCode: roomCode, values: ["toolbarExpanded": toolbarExpanded])
    }

    func updatePortraitControls(roomCode: String, blurLevel: String, strength: Int, effect: String) async throws {
        try await update(roomCode: roomCode, values: [
            "portraitBlurLevel": Self.safePortraitEffect(blurLevel),
            "portraitStrength": Self.safePortraitStrength(strength),
            "portraitEffect": Self.safePortraitEffect(effect)
        ])
    }

    func updatePortraitSubjectState(roomCode: String, state: PortraitSubjectState) async throws {
        let bounds = Self.clampedBounds(state.faceBounds)
        try await update(roomCode: roomCode, values: [
            "portraitStatus": state.status,
            "portraitFaceLeft": bounds.left,
            "portraitFaceTop": bounds.top,
            "portraitFaceRight": bounds.right,
            "portraitFaceBottom": bounds.bottom
        ])
    }

    func updateFaceDetectionOverlay(roomCode: String, state: FaceDetectionOverlayState) async throws {
        try await update(roomCode: roomCode, values: [
            "faceDetected": state.detected,
            "faceCount": max(0, state.count),
            "faceDetectionTimestamp": state.timestamp,
            "faceBox": Self.encodeFaceBounds(Self.clampedBounds(state.primaryBox)),
            "faceBoxes": FirestoreValue.array(state.boxes.map { Self.encodeFaceBounds(Self.clampedBounds($0)) })
        ])
    }

    func updateSceneDetectionEnabled(roomCode: String, sceneDetectionEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["sceneDetectionEnabled": sceneDetectionEnabled])
    }

    func updateSceneDetectionState(roomCode: String, state: SceneDetectionState) async throws {
        try await update(roomCode: roomCode, values: [
            "sceneDetectionKey": state.key,
            "sceneDetectionLabel": state.label,
            "sceneDetectionSuggestion": state.suggestion,
            "sceneDetectionConfidence": state.confidence,
            "sceneDetectionTimestamp": state.timestamp,
            "sceneDetectionAutoAdjustment": state.autoAdjustment
        ])
    }

    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws {
        try await update(roomCode: roomCode, values: ["aspectRatioMode": Self.safeAspectRatioMode(aspectRatioMode)])
    }

    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int64, lockEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: [
            "focusPointX": min(1.0, max(0.0, x)),
            "focusPointY": min(1.0, max(0.0, y)),
            "focusRequestId": requestId,
            "focusLockEnabled": lockEnabled
        ])
    }

    func updateExposureState(roomCode: String, state: ExposureState) async throws {
        let maxIndex = max(state.minIndex, state.maxIndex)
        try await update(roomCode: roomCode, values: [
            "exposureMinIndex": state.minIndex,
            "exposureMaxIndex": maxIndex,
            "exposureIndex": min(maxIndex, max(state.minIndex, state.currentIndex))
        ])
    }

    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws {
        try await update(roomCode: roomCode, values: ["exposureIndex": exposureIndex])
    }

    func updateFlashSupported(roomCode: String, flashSupported: Bool) async throws {
        var values: [String: Any] = ["flashSupported": flashSupported]
        if !flashSupported {
            values["flashEnabled"] = false
            values["flashMode"] = "off"
        }
        try await update(roomCode: roomCode, values: values)
    }

    func updatePreviewSize(roomCode: String, width: Int, height: Int) async throws {
        try await update(roomCode: roomCode, values: [
            "previewWidth": max(0, width),
            "previewHeight": max(0, height)
        ])
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

    func clearIceCandidates(roomCode: String) async throws {
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

    private nonisolated static func makeRoomCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<5).compactMap { _ in chars.randomElement() })
    }

    private nonisolated static func safeAspectRatioMode(_ mode: String) -> String {
        RoomSchema.safeAspectRatioMode(mode)
    }

    private nonisolated static func safeCameraMode(_ mode: String) -> String {
        RoomSchema.safeCameraMode(mode)
    }

    private nonisolated static func safeFlashMode(_ mode: String) -> String {
        RoomSchema.safeFlashMode(mode)
    }

    private nonisolated static func safeCaptureRequestType(_ type: String) -> String {
        RoomSchema.safeCaptureRequestType(type)
    }

    private nonisolated static func safePortraitEffect(_ effect: String) -> String {
        RoomSchema.safePortraitEffect(effect)
    }

    private nonisolated static func safePortraitStrength(_ strength: Int) -> Int {
        RoomSchema.safePortraitStrength(strength)
    }

    private nonisolated static func clampedUnit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private nonisolated static func clampedBounds(_ bounds: NormalizedFaceBounds) -> NormalizedFaceBounds {
        NormalizedFaceBounds(
            left: clampedUnit(bounds.left),
            top: clampedUnit(bounds.top),
            right: clampedUnit(bounds.right),
            bottom: clampedUnit(bounds.bottom)
        )
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
            "captureRequestId": .integer(room.captureRequestId),
            "captureRequestType": .string(room.captureRequestType),
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
            "portraitBlurLevel": .string(room.portraitBlurLevel),
            "portraitStrength": .integer(room.portraitStrength),
            "portraitEffect": .string(room.portraitEffect),
            "portraitStatus": .string(room.portraitStatus),
            "portraitFaceLeft": .double(room.portraitFaceLeft),
            "portraitFaceTop": .double(room.portraitFaceTop),
            "portraitFaceRight": .double(room.portraitFaceRight),
            "portraitFaceBottom": .double(room.portraitFaceBottom),
            "faceDetected": .bool(room.faceDetected),
            "faceCount": .integer(room.faceCount),
            "faceDetectionTimestamp": .integer(room.faceDetectionTimestamp),
            "faceBox": encodeFaceBounds(room.faceBox),
            "faceBoxes": .array(room.faceBoxes.map(encodeFaceBounds)),
            "sceneDetectionEnabled": .bool(room.sceneDetectionEnabled),
            "sceneDetectionKey": .string(room.sceneDetection.key),
            "sceneDetectionLabel": .string(room.sceneDetection.label),
            "sceneDetectionSuggestion": .string(room.sceneDetection.suggestion),
            "sceneDetectionConfidence": .double(room.sceneDetection.confidence),
            "sceneDetectionTimestamp": .integer(room.sceneDetection.timestamp),
            "sceneDetectionAutoAdjustment": .string(room.sceneDetection.autoAdjustment),
            "sessionVersion": .integer(room.sessionVersion),
            "updatedAt": .timestamp(room.updatedAt)
        ]
        if let offer = room.offer { fields["offer"] = .string(offer) }
        if let answer = room.answer { fields["answer"] = .string(answer) }
        if let rtcSessionId = room.rtcSessionId { fields["rtcSessionId"] = .string(rtcSessionId) }
        return fields
    }

    private static func decodeRoom(_ data: [String: FirestoreValue]) -> RoomDocument? {
        guard let roomCode = data["roomCode"]?.stringValue else { return nil }
        let captureFields = data["captureRequest"]?.mapValue?.fields
        let captureRequest: CaptureRequest?
        if let captureFields {
            let id = captureFields["id"]?.int64Value ?? 0
            captureRequest = CaptureRequest(
                id: id,
                type: captureFields["type"]?.stringValue ?? "photo",
                requestedAt: captureFields["requestedAt"]?.dateValue ?? Date()
            )
        } else if data["captureRequest"]?.booleanValue == true {
            let id = data["captureRequestId"]?.int64Value ?? 0
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
            captureRequestId: captureRequest?.id ?? 0,
            captureRequestType: captureRequest?.type ?? "photo",
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
            focusRequestId: data["focusRequestId"]?.int64Value ?? 0,
            focusPointX: data["focusPointX"]?.numberValue ?? 0.5,
            focusPointY: data["focusPointY"]?.numberValue ?? 0.5,
            focusLockEnabled: data["focusLockEnabled"]?.booleanValue ?? false,
            exposureMinIndex: data["exposureMinIndex"]?.integerNumberValue ?? 0,
            exposureMaxIndex: data["exposureMaxIndex"]?.integerNumberValue ?? 0,
            exposureIndex: data["exposureIndex"]?.integerNumberValue ?? 0,
            streamQualityMode: StreamQualityMode(rawValue: data["streamQualityMode"]?.stringValue ?? "") ?? .lowLatency,
            rtcSessionId: data["rtcSessionId"]?.stringValue,
            sessionVersion: data["sessionVersion"]?.int64Value ?? 0,
            previewWidth: data["previewWidth"]?.integerNumberValue ?? 0,
            previewHeight: data["previewHeight"]?.integerNumberValue ?? 0,
            portraitBlurLevel: Self.safePortraitEffect(data["portraitBlurLevel"]?.stringValue ?? RoomSchema.defaultPortraitEffect),
            portraitStrength: Self.safePortraitStrength(data["portraitStrength"]?.integerNumberValue ?? RoomSchema.defaultPortraitStrength),
            portraitEffect: Self.safePortraitEffect(data["portraitEffect"]?.stringValue ?? RoomSchema.defaultPortraitEffect),
            portraitStatus: data["portraitStatus"]?.stringValue ?? "finding",
            portraitFaceLeft: data["portraitFaceLeft"]?.numberValue ?? data["portraitSubjectX"]?.numberValue ?? 0,
            portraitFaceTop: data["portraitFaceTop"]?.numberValue ?? data["portraitSubjectY"]?.numberValue ?? 0,
            portraitFaceRight: data["portraitFaceRight"]?.numberValue ?? ((data["portraitSubjectX"]?.numberValue ?? 0) + (data["portraitSubjectWidth"]?.numberValue ?? 0)),
            portraitFaceBottom: data["portraitFaceBottom"]?.numberValue ?? ((data["portraitSubjectY"]?.numberValue ?? 0) + (data["portraitSubjectHeight"]?.numberValue ?? 0)),
            faceDetected: data["faceDetected"]?.booleanValue ?? false,
            faceCount: data["faceCount"]?.integerNumberValue ?? 0,
            faceDetectionTimestamp: data["faceDetectionTimestamp"]?.int64Value ?? 0,
            faceBox: decodeFaceBounds(data["faceBox"]) ?? NormalizedFaceBounds(
                left: data["faceBoxLeft"]?.numberValue ?? 0,
                top: data["faceBoxTop"]?.numberValue ?? 0,
                right: data["faceBoxRight"]?.numberValue ?? 0,
                bottom: data["faceBoxBottom"]?.numberValue ?? 0
            ),
            faceBoxes: decodeFaceBoundsArray(data["faceBoxes"]),
            sceneDetectionEnabled: data["sceneDetectionEnabled"]?.booleanValue ?? false,
            sceneDetection: SceneDetectionState(
                key: data["sceneDetectionKey"]?.stringValue ?? data["sceneKey"]?.stringValue ?? "auto",
                label: data["sceneDetectionLabel"]?.stringValue ?? data["sceneLabel"]?.stringValue ?? "",
                suggestion: data["sceneDetectionSuggestion"]?.stringValue ?? data["sceneSuggestion"]?.stringValue ?? "",
                confidence: data["sceneDetectionConfidence"]?.numberValue ?? data["sceneConfidence"]?.numberValue ?? 0,
                timestamp: data["sceneDetectionTimestamp"]?.int64Value ?? data["sceneTimestamp"]?.int64Value ?? 0,
                autoAdjustment: data["sceneDetectionAutoAdjustment"]?.stringValue ?? data["sceneAutoAdjustment"]?.stringValue ?? ""
            ),
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
        if let value = value as? Int64 { return .integer(Int(value)) }
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

    private nonisolated static func encodeFaceBounds(_ bounds: NormalizedFaceBounds) -> FirestoreValue {
        .map([
            "left": .double(bounds.left),
            "top": .double(bounds.top),
            "right": .double(bounds.right),
            "bottom": .double(bounds.bottom)
        ])
    }

    private static func decodeFaceBounds(_ value: FirestoreValue?) -> NormalizedFaceBounds? {
        guard let fields = value?.mapValue?.fields else { return nil }
        return NormalizedFaceBounds(
            left: fields["left"]?.numberValue ?? 0,
            top: fields["top"]?.numberValue ?? 0,
            right: fields["right"]?.numberValue ?? 0,
            bottom: fields["bottom"]?.numberValue ?? 0
        )
    }

    private static func decodeFaceBoundsArray(_ value: FirestoreValue?) -> [NormalizedFaceBounds] {
        guard let values = value?.arrayValue?.values else { return [] }
        return values.compactMap(decodeFaceBounds)
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

    var int64Value: Int64? {
        if let integerValue { return Int64(integerValue) }
        if let doubleValue { return Int64(doubleValue) }
        if let stringValue { return Int64(stringValue) }
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

    static func integer(_ value: Int64) -> FirestoreValue {
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
            "captureRequest": false,
            "captureRequestId": 0,
            "captureRequestType": "photo",
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
            "captureRequestId": 0,
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

    func updateLensFacing(roomCode: String, lensFacing: LensFacing) async throws {
        try await update(roomCode: roomCode, values: ["lensFacing": lensFacing.rawValue])
    }

    func updateZoomLevel(roomCode: String, zoomLevel: Double) async throws {
        try await update(roomCode: roomCode, values: ["zoomLevel": max(1.0, min(8.0, zoomLevel))])
    }

    func updateZoomRange(roomCode: String, minZoom: Double, maxZoom: Double) async throws {
        let safeMinZoom = max(1.0, minZoom)
        try await update(roomCode: roomCode, values: [
            "minZoom": safeMinZoom,
            "maxZoom": max(safeMinZoom, maxZoom)
        ])
    }

    func updateFlashMode(roomCode: String, flashMode: String) async throws {
        let safeFlashMode = Self.safeFlashMode(flashMode)
        try await update(roomCode: roomCode, values: [
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

    func updateNightModeEnabled(roomCode: String, nightModeEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["nightModeEnabled": nightModeEnabled])
    }

    func updateVideoHdrEnabled(roomCode: String, videoHdrEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["videoHdrEnabled": videoHdrEnabled])
    }

    func updateToolbarExpanded(roomCode: String, toolbarExpanded: Bool) async throws {
        try await update(roomCode: roomCode, values: ["toolbarExpanded": toolbarExpanded])
    }

    func updatePortraitControls(roomCode: String, blurLevel: String, strength: Int, effect: String) async throws {
        try await update(roomCode: roomCode, values: [
            "portraitBlurLevel": Self.safePortraitEffect(blurLevel),
            "portraitStrength": Self.safePortraitStrength(strength),
            "portraitEffect": Self.safePortraitEffect(effect)
        ])
    }

    func updatePortraitSubjectState(roomCode: String, state: PortraitSubjectState) async throws {
        let bounds = Self.clampedBounds(state.faceBounds)
        try await update(roomCode: roomCode, values: [
            "portraitStatus": state.status,
            "portraitFaceLeft": bounds.left,
            "portraitFaceTop": bounds.top,
            "portraitFaceRight": bounds.right,
            "portraitFaceBottom": bounds.bottom
        ])
    }

    func updateFaceDetectionOverlay(roomCode: String, state: FaceDetectionOverlayState) async throws {
        try await update(roomCode: roomCode, values: [
            "faceDetected": state.detected,
            "faceCount": max(0, state.count),
            "faceDetectionTimestamp": state.timestamp,
            "faceBox": Self.encodeFaceBounds(Self.clampedBounds(state.primaryBox)),
            "faceBoxes": state.boxes.map { Self.encodeFaceBounds(Self.clampedBounds($0)) }
        ])
    }

    func updateSceneDetectionEnabled(roomCode: String, sceneDetectionEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: ["sceneDetectionEnabled": sceneDetectionEnabled])
    }

    func updateSceneDetectionState(roomCode: String, state: SceneDetectionState) async throws {
        try await update(roomCode: roomCode, values: [
            "sceneDetectionKey": state.key,
            "sceneDetectionLabel": state.label,
            "sceneDetectionSuggestion": state.suggestion,
            "sceneDetectionConfidence": state.confidence,
            "sceneDetectionTimestamp": state.timestamp,
            "sceneDetectionAutoAdjustment": state.autoAdjustment
        ])
    }

    func updateAspectRatioMode(roomCode: String, aspectRatioMode: String) async throws {
        try await update(roomCode: roomCode, values: ["aspectRatioMode": Self.safeAspectRatioMode(aspectRatioMode)])
    }

    func updateFocusRequest(roomCode: String, x: Double, y: Double, requestId: Int64, lockEnabled: Bool) async throws {
        try await update(roomCode: roomCode, values: [
            "focusPointX": min(1.0, max(0.0, x)),
            "focusPointY": min(1.0, max(0.0, y)),
            "focusRequestId": requestId,
            "focusLockEnabled": lockEnabled
        ])
    }

    func updateExposureState(roomCode: String, state: ExposureState) async throws {
        let maxIndex = max(state.minIndex, state.maxIndex)
        try await update(roomCode: roomCode, values: [
            "exposureMinIndex": state.minIndex,
            "exposureMaxIndex": maxIndex,
            "exposureIndex": min(maxIndex, max(state.minIndex, state.currentIndex))
        ])
    }

    func updateExposureIndex(roomCode: String, exposureIndex: Int) async throws {
        try await update(roomCode: roomCode, values: ["exposureIndex": exposureIndex])
    }

    func updateFlashSupported(roomCode: String, flashSupported: Bool) async throws {
        var values: [String: Any] = ["flashSupported": flashSupported]
        if !flashSupported {
            values["flashEnabled"] = false
            values["flashMode"] = "off"
        }
        try await update(roomCode: roomCode, values: values)
    }

    func updatePreviewSize(roomCode: String, width: Int, height: Int) async throws {
        try await update(roomCode: roomCode, values: [
            "previewWidth": max(0, width),
            "previewHeight": max(0, height)
        ])
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

    func clearIceCandidates(roomCode: String) async throws {
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
            "captureRequestId": room.captureRequestId,
            "captureRequestType": room.captureRequestType,
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
            "portraitBlurLevel": room.portraitBlurLevel,
            "portraitStrength": room.portraitStrength,
            "portraitEffect": room.portraitEffect,
            "portraitStatus": room.portraitStatus,
            "portraitFaceLeft": room.portraitFaceLeft,
            "portraitFaceTop": room.portraitFaceTop,
            "portraitFaceRight": room.portraitFaceRight,
            "portraitFaceBottom": room.portraitFaceBottom,
            "faceDetected": room.faceDetected,
            "faceCount": room.faceCount,
            "faceDetectionTimestamp": room.faceDetectionTimestamp,
            "faceBox": encodeFaceBounds(room.faceBox),
            "faceBoxes": room.faceBoxes.map(encodeFaceBounds),
            "sceneDetectionEnabled": room.sceneDetectionEnabled,
            "sceneDetectionKey": room.sceneDetection.key,
            "sceneDetectionLabel": room.sceneDetection.label,
            "sceneDetectionSuggestion": room.sceneDetection.suggestion,
            "sceneDetectionConfidence": room.sceneDetection.confidence,
            "sceneDetectionTimestamp": room.sceneDetection.timestamp,
            "sceneDetectionAutoAdjustment": room.sceneDetection.autoAdjustment,
            "sessionVersion": room.sessionVersion,
            "updatedAt": Timestamp(date: room.updatedAt),
            "createdAt": Timestamp(date: Date())
        ]
    }

    private static func decodeRoom(_ data: [String: Any]) -> RoomDocument? {
        guard let roomCode = data["roomCode"] as? String else { return nil }
        let flashMode = Self.safeFlashMode(data["flashMode"] as? String ?? ((data["flashEnabled"] as? Bool) == true ? "on" : "off"))
        let captureRequest: CaptureRequest?
        if let captureFields = data["captureRequest"] as? [String: Any] {
            captureRequest = CaptureRequest(
                id: Self.int64Value(captureFields["id"]),
                type: captureFields["type"] as? String ?? RoomSchema.defaultCaptureRequestType,
                requestedAt: (captureFields["requestedAt"] as? Timestamp)?.dateValue() ?? Date()
            )
        } else if (data["captureRequest"] as? Bool) == true {
            captureRequest = CaptureRequest(
                id: Self.int64Value(data["captureRequestId"]),
                type: data["captureRequestType"] as? String ?? RoomSchema.defaultCaptureRequestType,
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
            captureRequestId: captureRequest?.id ?? 0,
            captureRequestType: captureRequest?.type ?? "photo",
            lensFacing: LensFacing(rawValue: data["lensFacing"] as? String ?? "back") ?? .back,
            zoomLevel: Self.doubleValue(data["zoomLevel"], default: 1.0),
            minZoom: Self.doubleValue(data["minZoom"], default: 1.0),
            maxZoom: Self.doubleValue(data["maxZoom"], default: 8.0),
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
            focusRequestId: Self.int64Value(data["focusRequestId"]),
            focusPointX: Self.doubleValue(data["focusPointX"], default: 0.5),
            focusPointY: Self.doubleValue(data["focusPointY"], default: 0.5),
            focusLockEnabled: data["focusLockEnabled"] as? Bool ?? false,
            exposureMinIndex: Self.intValue(data["exposureMinIndex"]),
            exposureMaxIndex: Self.intValue(data["exposureMaxIndex"]),
            exposureIndex: Self.intValue(data["exposureIndex"]),
            streamQualityMode: StreamQualityMode(rawValue: data["streamQualityMode"] as? String ?? "") ?? .lowLatency,
            rtcSessionId: data["rtcSessionId"] as? String,
            sessionVersion: Self.int64Value(data["sessionVersion"]),
            previewWidth: Self.intValue(data["previewWidth"]),
            previewHeight: Self.intValue(data["previewHeight"]),
            portraitBlurLevel: Self.safePortraitEffect(data["portraitBlurLevel"] as? String ?? RoomSchema.defaultPortraitEffect),
            portraitStrength: Self.safePortraitStrength(Self.intValue(data["portraitStrength"], default: RoomSchema.defaultPortraitStrength)),
            portraitEffect: Self.safePortraitEffect(data["portraitEffect"] as? String ?? RoomSchema.defaultPortraitEffect),
            portraitStatus: data["portraitStatus"] as? String ?? "finding",
            portraitFaceLeft: Self.doubleValue(data["portraitFaceLeft"], fallback: data["portraitSubjectX"]),
            portraitFaceTop: Self.doubleValue(data["portraitFaceTop"], fallback: data["portraitSubjectY"]),
            portraitFaceRight: Self.doubleValue(
                data["portraitFaceRight"],
                default: Self.doubleValue(data["portraitSubjectX"]) + Self.doubleValue(data["portraitSubjectWidth"])
            ),
            portraitFaceBottom: Self.doubleValue(
                data["portraitFaceBottom"],
                default: Self.doubleValue(data["portraitSubjectY"]) + Self.doubleValue(data["portraitSubjectHeight"])
            ),
            faceDetected: data["faceDetected"] as? Bool ?? false,
            faceCount: Self.intValue(data["faceCount"]),
            faceDetectionTimestamp: Self.int64Value(data["faceDetectionTimestamp"]),
            faceBox: decodeFaceBounds(data["faceBox"]) ?? NormalizedFaceBounds(
                left: Self.doubleValue(data["faceBoxLeft"]),
                top: Self.doubleValue(data["faceBoxTop"]),
                right: Self.doubleValue(data["faceBoxRight"]),
                bottom: Self.doubleValue(data["faceBoxBottom"])
            ),
            faceBoxes: decodeFaceBoundsArray(data["faceBoxes"]),
            sceneDetectionEnabled: data["sceneDetectionEnabled"] as? Bool ?? false,
            sceneDetection: SceneDetectionState(
                key: data["sceneDetectionKey"] as? String ?? data["sceneKey"] as? String ?? "auto",
                label: data["sceneDetectionLabel"] as? String ?? data["sceneLabel"] as? String ?? "",
                suggestion: data["sceneDetectionSuggestion"] as? String ?? data["sceneSuggestion"] as? String ?? "",
                confidence: Self.doubleValue(data["sceneDetectionConfidence"], fallback: data["sceneConfidence"]),
                timestamp: Self.int64Value(data["sceneDetectionTimestamp"]) != 0 ? Self.int64Value(data["sceneDetectionTimestamp"]) : Self.int64Value(data["sceneTimestamp"]),
                autoAdjustment: data["sceneDetectionAutoAdjustment"] as? String ?? data["sceneAutoAdjustment"] as? String ?? ""
            ),
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
        let index = intValue(data["sdpMLineIndex"])
        return IceCandidatePayload(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: Int32(index))
    }

    private nonisolated static func encodeFaceBounds(_ bounds: NormalizedFaceBounds) -> [String: Any] {
        [
            "left": bounds.left,
            "top": bounds.top,
            "right": bounds.right,
            "bottom": bounds.bottom
        ]
    }

    private static func decodeFaceBounds(_ value: Any?) -> NormalizedFaceBounds? {
        guard let fields = value as? [String: Any] else { return nil }
        return NormalizedFaceBounds(
            left: doubleValue(fields["left"]),
            top: doubleValue(fields["top"]),
            right: doubleValue(fields["right"]),
            bottom: doubleValue(fields["bottom"])
        )
    }

    private static func decodeFaceBoundsArray(_ value: Any?) -> [NormalizedFaceBounds] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.compactMap(decodeFaceBounds)
    }

    private static func doubleValue(_ value: Any?, fallback: Any? = nil, default defaultValue: Double = 0) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let parsed = Double(value) { return parsed }
        if let fallback { return doubleValue(fallback, default: defaultValue) }
        return defaultValue
    }

    private static func intValue(_ value: Any?, default defaultValue: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return defaultValue
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
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
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<5).compactMap { _ in chars.randomElement() })
    }

    private static func safeAspectRatioMode(_ mode: String) -> String {
        RoomSchema.safeAspectRatioMode(mode)
    }

    private static func safeCameraMode(_ mode: String) -> String {
        RoomSchema.safeCameraMode(mode)
    }

    private static func safeFlashMode(_ mode: String) -> String {
        RoomSchema.safeFlashMode(mode)
    }

    private static func safeCaptureRequestType(_ type: String) -> String {
        RoomSchema.safeCaptureRequestType(type)
    }

    private static func safePortraitEffect(_ effect: String) -> String {
        RoomSchema.safePortraitEffect(effect)
    }

    private static func safePortraitStrength(_ strength: Int) -> Int {
        RoomSchema.safePortraitStrength(strength)
    }

    private static func clampedUnit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func clampedBounds(_ bounds: NormalizedFaceBounds) -> NormalizedFaceBounds {
        NormalizedFaceBounds(
            left: clampedUnit(bounds.left),
            top: clampedUnit(bounds.top),
            right: clampedUnit(bounds.right),
            bottom: clampedUnit(bounds.bottom)
        )
    }
}
#endif
