import Foundation
import Photos

struct PhotoSaveOutcome: Sendable {
    let localURL: URL?
    let message: String
}

protocol PhotoSaving: Sendable {
    func prewarm() async
    func savePhoto(_ data: Data) async -> PhotoSaveOutcome
    func savePhotoToAppStorage(_ data: Data) async -> PhotoSaveOutcome
    func savePhotoToCameraRoll(_ data: Data) async -> PhotoSaveOutcome
    func saveVideo(at url: URL) async -> PhotoSaveOutcome
}

struct PhotoLibrarySavingService: PhotoSaving {
    func prewarm() async {
        await Task.detached(priority: .utility) {
            _ = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            _ = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }.value
    }

    func savePhoto(_ data: Data) async -> PhotoSaveOutcome {
        let localOutcome = await savePhotoToAppStorage(data)

        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            return PhotoSaveOutcome(
                localURL: localOutcome.localURL,
                message: "Saved in app storage. Add Photos permission to save to Camera Roll."
            )
        }

        do {
            try await savePhotoToLibrary(data)
            return PhotoSaveOutcome(localURL: localOutcome.localURL, message: "Saved to Photos.")
        } catch {
            let prefix = localOutcome.localURL == nil ? "Photo captured, but local save failed." : "Saved in app storage."
            return PhotoSaveOutcome(localURL: localOutcome.localURL, message: "\(prefix) Photos save failed: \(error.localizedDescription)")
        }
    }

    func savePhotoToAppStorage(_ data: Data) async -> PhotoSaveOutcome {
        do {
            let localURL = try await saveToDocuments(data)
            return PhotoSaveOutcome(localURL: localURL, message: "Saved in app storage. Adding to Photos in background.")
        } catch {
            return PhotoSaveOutcome(localURL: nil, message: "Photo captured, but local save failed: \(error.localizedDescription)")
        }
    }

    func savePhotoToCameraRoll(_ data: Data) async -> PhotoSaveOutcome {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            return PhotoSaveOutcome(localURL: nil, message: "Add Photos permission to save to Camera Roll.")
        }

        do {
            try await savePhotoToLibrary(data)
            return PhotoSaveOutcome(localURL: nil, message: "Saved to Photos.")
        } catch {
            return PhotoSaveOutcome(localURL: nil, message: "Photos save failed: \(error.localizedDescription)")
        }
    }

    func saveVideo(at url: URL) async -> PhotoSaveOutcome {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            return PhotoSaveOutcome(
                localURL: url,
                message: "Video saved in app storage. Add Photos permission to save to Camera Roll."
            )
        }

        do {
            try await saveVideoToLibrary(url)
            return PhotoSaveOutcome(localURL: url, message: "Video saved to Photos.")
        } catch {
            return PhotoSaveOutcome(
                localURL: url,
                message: "Video saved in app storage. Photos save failed: \(error.localizedDescription)"
            )
        }
    }

    private func saveToDocuments(_ data: Data) async throws -> URL {
        let fileExtension = photoFileExtension(for: data)
        return try await Task.detached(priority: .utility) {
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
            let url = directory.appendingPathComponent("AI-Camera-\(safeTimestamp).\(fileExtension)")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func savePhotoToLibrary(_ data: Data) async throws {
        try await ensurePhotoLibraryWriteAccess()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
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

    private func saveVideoToLibrary(_ url: URL) async throws {
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

        guard authorized else {
            throw CocoaError(.userCancelled)
        }
    }

    private func photoFileExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        if data.count > 12,
           let fileType = String(data: data[4..<12], encoding: .ascii),
           fileType.hasPrefix("ftyphe") || fileType.hasPrefix("ftypms") {
            return "heic"
        }
        return "jpg"
    }
}
