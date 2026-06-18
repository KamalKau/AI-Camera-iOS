import SwiftUI

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
                let room = try await services.roomCreator.createRoom()
                path.append(AppRoute.cameraHost(roomCode: room.roomCode))
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreatingRoom = false
        }
    }
}
