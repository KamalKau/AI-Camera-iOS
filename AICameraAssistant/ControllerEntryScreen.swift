import SwiftUI

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
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: roomCode) { value in
                        roomCode = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(5))
                    }

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
                guard try await services.roomReader.room(roomCode: code) != nil else { throw RoomRepositoryError.roomNotFound }
                try await services.roomConnectionManager.requestConnection(roomCode: code)
                path.append(AppRoute.waitingForApproval(roomCode: code))
            } catch {
                errorMessage = error.localizedDescription
            }
            isRequesting = false
        }
    }
}
