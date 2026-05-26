import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct AICameraAssistantApp: App {
    init() {
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
