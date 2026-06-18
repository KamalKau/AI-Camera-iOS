import SwiftUI

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
