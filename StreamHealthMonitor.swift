import Foundation

@MainActor
final class StreamHealthMonitor {
    struct Configuration {
        let pollInterval: Duration
        let stalledCheckLimit: Int

        nonisolated static let controllerPreview = Configuration(
            pollInterval: .seconds(1),
            stalledCheckLimit: 4
        )
    }

    private let configuration: Configuration
    private var task: Task<Void, Never>?

    init(configuration: Configuration = .controllerPreview) {
        self.configuration = configuration
    }

    func start(
        isActive: @escaping @MainActor () -> Bool,
        decodedFrames: @escaping @MainActor () async -> Int?,
        onProgress: @escaping @MainActor (Int) -> Void,
        onStall: @escaping @MainActor () async -> Void
    ) {
        cancel()
        task = Task { @MainActor [configuration] in
            var lastDecodedFrames = -1
            var stalledChecks = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.pollInterval)
                guard isActive() else { continue }
                guard let frameCount = await decodedFrames() else { continue }

                if lastDecodedFrames >= 0, frameCount <= lastDecodedFrames {
                    stalledChecks += 1
                } else {
                    stalledChecks = 0
                    lastDecodedFrames = frameCount
                    onProgress(frameCount)
                }

                if stalledChecks >= configuration.stalledCheckLimit {
                    await onStall()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
