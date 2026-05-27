import SwiftUI

struct StreamDiagnosticsView: View {
    let state: WebRtcConnectionState
    let qualityMode: StreamQualityMode
    let iceState: String
    let decodedFrames: Int
    let reconnectCount: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(qualityMode.label)
                .font(.caption.weight(.semibold))
            Text("RTC \(state.rawValue) | ICE \(iceState)")
                .font(.caption2)
            if decodedFrames > 0 || reconnectCount > 0 {
                Text("Frames \(decodedFrames) | Retries \(reconnectCount)")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .monospacedDigit()
    }
}
