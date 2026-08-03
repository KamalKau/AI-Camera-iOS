import Foundation
import Photos

protocol BoomerangPhotoLibrarySaving {
    func saveBoomerang(at url: URL) async -> String
}

final class DefaultBoomerangPhotoLibrarySaver: BoomerangPhotoLibrarySaving {
    func saveBoomerang(at url: URL) async -> String {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            return "Boomerang exported. Add Photos permission text to save to Camera Roll."
        }

        do {
            try await ensurePhotoLibraryWriteAccess()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
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
            return "Boomerang saved to Photos."
        } catch {
            return "Boomerang save failed: \(error.localizedDescription)"
        }
    }

    private func ensurePhotoLibraryWriteAccess() async throws {
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
        guard authorized else { throw CocoaError(.userCancelled) }
    }
}
