import Combine
import Foundation
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

@MainActor
final class AppServices: ObservableObject {
    let roomRepository: any RoomRepository
    let webRtcSession: WebRtcSessionManager
    private var webRtcCancellable: AnyCancellable?

    var roomCreator: any RoomCreating { roomRepository }
    var roomReader: any RoomReading { roomRepository }
    var roomConnectionManager: any RoomConnectionManaging { roomRepository }

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
