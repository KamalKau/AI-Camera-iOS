import SwiftUI

struct ControllerEntryScreen: View {
    @EnvironmentObject private var services: AppServices
    @Binding var path: NavigationPath
    @State private var roomCode = ""
    @State private var isRequesting = false
    @State private var errorMessage: String?
    @FocusState private var isRoomCodeFocused: Bool

    private var cleanedRoomCode: String {
        roomCode.normalizedRoomCode
    }

    private var canConnect: Bool {
        !cleanedRoomCode.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 720
            let horizontalPadding = min(max(18, geometry.size.width * 0.055), 22)
            let topInset: CGFloat = isCompact ? 70 : 86

            ZStack {
                AndroidHomeWallpaper()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        ControllerConnectCard(
                            roomCode: $roomCode,
                            isFocused: $isRoomCodeFocused,
                            errorMessage: errorMessage,
                            canConnect: canConnect,
                            isRequesting: isRequesting,
                            isCompact: isCompact,
                            onCodeChanged: { errorMessage = nil },
                            onConnect: requestConnection
                        )
                        .frame(maxWidth: 420)

                        Text("The camera phone must be open and waiting for controller approval.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.72).opacity(0.74))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(geometry.size.height - topInset, 0), alignment: .center)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topInset)
                    .padding(.bottom, isCompact ? 18 : 24)
                }

                ControllerBackPill {
                    errorMessage = nil
                    if !path.isEmpty { path.removeLast() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, isCompact ? 14 : 20)
                .padding(.leading, horizontalPadding)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isRoomCodeFocused = true }
    }

    private func requestConnection() {
        guard canConnect, !isRequesting else { return }
        isRequesting = true
        errorMessage = nil
        let code = cleanedRoomCode
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

private struct ControllerBackPill: View {
    let onBack: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.49, green: 0.30, blue: 1.0).opacity(pulse ? 0.24 : 0.14))
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                Text("Back")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 7)
            .padding(.trailing, 13)
            .padding(.vertical, 7)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.08, blue: 0.24).opacity(0.92),
                        Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.50), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct ControllerConnectCard: View {
    @Binding var roomCode: String
    @FocusState.Binding var isFocused: Bool
    let errorMessage: String?
    let canConnect: Bool
    let isRequesting: Bool
    let isCompact: Bool
    let onCodeChanged: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: isCompact ? 12 : 14) {
            AndroidPurpleCameraLogo()
                .frame(width: isCompact ? 66 : 78, height: isCompact ? 66 : 78)

            VStack(spacing: 5) {
                Text("Control Camera")
                    .font(.system(size: isCompact ? 23 : 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Enter the camera phone room code")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.72))
                    .multilineTextAlignment(.center)
            }

            ZStack {
                TextField("", text: $roomCode)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: roomCode) { _, newValue in
                        onCodeChanged()
                        let nextCode = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(5))
                        if roomCode != nextCode {
                            roomCode = nextCode
                        }
                        if nextCode.count == 5 {
                            isFocused = false
                        }
                    }
                    .submitLabel(.go)
                    .onSubmit(onConnect)

                RoomCodePreview(code: roomCode.normalizedRoomCode)
                    .contentShape(Rectangle())
                    .onTapGesture { isFocused = true }
            }
            .padding(.top, 2)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.71, blue: 0.76))
                    .multilineTextAlignment(.center)
            }

            Button(action: onConnect) {
                HStack(spacing: 8) {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        ConnectSensorsIcon()
                            .frame(width: 19, height: 19)
                    }
                    Text(isRequesting ? "Connecting" : "Connect")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    Color(red: 0.49, green: 0.30, blue: 1.0).opacity(canConnect ? 1.0 : 0.22),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConnect || isRequesting)
            .opacity(canConnect ? 1.0 : 0.72)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.08, blue: 0.24).opacity(0.92),
                    Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.66), lineWidth: 1)
        )
    }
}

private struct ConnectSensorsIcon: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let color = Color.white
            let lineWidth = max(1.5, min(size.width, size.height) * 0.09)

            context.stroke(
                Path(ellipseIn: CGRect(x: size.width * 0.33, y: size.height * 0.33, width: size.width * 0.34, height: size.height * 0.34)),
                with: .color(color),
                lineWidth: lineWidth
            )

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - size.width * 0.07, y: center.y - size.height * 0.07, width: size.width * 0.14, height: size.height * 0.14)),
                with: .color(color)
            )

            drawRay(context: context, size: size, from: CGPoint(x: 0.50, y: 0.04), to: CGPoint(x: 0.50, y: 0.22), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.50, y: 0.78), to: CGPoint(x: 0.50, y: 0.96), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.04, y: 0.50), to: CGPoint(x: 0.22, y: 0.50), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.78, y: 0.50), to: CGPoint(x: 0.96, y: 0.50), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.18, y: 0.18), to: CGPoint(x: 0.30, y: 0.30), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.82, y: 0.18), to: CGPoint(x: 0.70, y: 0.30), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.18, y: 0.82), to: CGPoint(x: 0.30, y: 0.70), color: color, lineWidth: lineWidth)
            drawRay(context: context, size: size, from: CGPoint(x: 0.82, y: 0.82), to: CGPoint(x: 0.70, y: 0.70), color: color, lineWidth: lineWidth)
        }
    }

    private func drawRay(context: GraphicsContext, size: CGSize, from: CGPoint, to: CGPoint, color: Color, lineWidth: CGFloat) {
        var path = Path()
        path.move(to: CGPoint(x: size.width * from.x, y: size.height * from.y))
        path.addLine(to: CGPoint(x: size.width * to.x, y: size.height * to.y))
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }
}

private struct RoomCodePreview: View {
    let code: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<5, id: \.self) { index in
                let char = character(at: index)
                Text(char)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 46)
                    .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                char.isEmpty ? .white.opacity(0.18) : Color(red: 0.61, green: 0.43, blue: 1.0).opacity(0.90),
                                lineWidth: 1
                            )
                    )
            }
        }
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let stringIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[stringIndex])
    }
}
