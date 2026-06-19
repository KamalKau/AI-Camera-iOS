import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

enum WebRtcRole {
    case host
    case controller
}

enum WebRtcSessionError: LocalizedError {
    case factoryUnavailable
    case peerConnectionUnavailable
    case cameraUnavailable
    case microphoneUsageDescriptionMissing
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .factoryUnavailable:
            return "WebRTC factory is unavailable."
        case .peerConnectionUnavailable:
            return "WebRTC peer connection is unavailable."
        case .cameraUnavailable:
            return "Camera is unavailable for recording."
        case .microphoneUsageDescriptionMissing:
            return "Microphone usage description is missing in target Info settings."
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        }
    }
}

#if canImport(WebRTC)
struct WebRtcStreamProfile {
    let width: Int
    let height: Int
    let fps: Int
    let minBitrate: Int
    let maxBitrate: Int

    func adjusted(for lensFacing: LensFacing) -> WebRtcStreamProfile {
        guard lensFacing == .back, width <= 640, height <= 360 else { return self }
        return WebRtcStreamProfile(
            width: 854,
            height: 480,
            fps: fps,
            minBitrate: minBitrate,
            maxBitrate: maxBitrate
        )
    }
}

extension StreamQualityMode {
    var webRtcProfile: WebRtcStreamProfile {
        switch self {
        case .lowLatency:
            return WebRtcStreamProfile(width: 640, height: 360, fps: 20, minBitrate: 600_000, maxBitrate: 1_800_000)
        case .balanced:
            return WebRtcStreamProfile(width: 854, height: 480, fps: 20, minBitrate: 900_000, maxBitrate: 2_600_000)
        case .quality:
            return WebRtcStreamProfile(width: 1280, height: 720, fps: 20, minBitrate: 1_400_000, maxBitrate: 4_000_000)
        }
    }
}

extension RTCIceConnectionState {
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
