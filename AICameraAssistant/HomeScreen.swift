import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject private var services: AppServices
    @Binding var path: NavigationPath
    @State private var stage: HomeStage = .landing
    @State private var isCreatingRoom = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            switch stage {
            case .landing:
                AndroidLandingScreen {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        stage = .welcome
                    }
                }
                .transition(.opacity)
            case .welcome:
                AndroidWelcomeScreen {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        stage = .home
                    }
                }
                .transition(.opacity)
            case .home:
                HomeActionScreen(
                    isCreatingRoom: isCreatingRoom,
                    errorMessage: errorMessage,
                    onStartCamera: createRoom,
                    onControlCamera: { path.append(AppRoute.controllerEntry) }
                )
                .transition(.opacity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
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

private enum HomeStage {
    case landing
    case welcome
    case home
}

private struct HomeActionScreen: View {
    let isCreatingRoom: Bool
    let errorMessage: String?
    let onStartCamera: () -> Void
    let onControlCamera: () -> Void
    @State private var contentVisible = false

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 720
            let logoSize: CGFloat = isCompact ? 84 : 112
            let titleSize: CGFloat = isCompact ? 26 : 30
            let horizontalPadding = min(max(20, geometry.size.width * 0.055), 24)

            ZStack {
                AndroidHomeWallpaper()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: isCompact ? 14 : 28)

                        VStack(spacing: 0) {
                            AndroidPurpleCameraLogo()
                                .frame(width: logoSize, height: logoSize)
                                .padding(.bottom, isCompact ? 12 : 18)
                                .scaleEffect(contentVisible ? 1 : 0.84)
                                .opacity(contentVisible ? 1 : 0)

                            Text("AI Camera")
                                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Text("Assistant")
                                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [
                                            .white,
                                            Color(red: 0.61, green: 0.43, blue: 1.0),
                                            Color(red: 0.49, green: 0.30, blue: 1.0)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .padding(.bottom, 8)

                            Text("Professional remote camera control\nfrom anywhere")
                                .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                                .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.72))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.bottom, isCompact ? 18 : 26)
                        }
                        .offset(y: contentVisible ? 0 : 18)
                        .opacity(contentVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.52), value: contentVisible)

                        VStack(spacing: 12) {
                            HomeActionCard(
                                icon: .remote,
                                title: isCreatingRoom ? "Creating Room" : "Start Camera",
                                subtitle: "Use this phone as the live camera",
                                style: .primary,
                                isLoading: isCreatingRoom,
                                action: onStartCamera
                            )
                            .disabled(isCreatingRoom)

                            HomeActionCard(
                                icon: .scene,
                                title: "Control Camera",
                                subtitle: "Connect and control another phone",
                                style: .secondary,
                                isLoading: false,
                                action: onControlCamera
                            )
                        }
                        .frame(maxWidth: 420)
                        .offset(y: contentVisible ? 0 : 22)
                        .opacity(contentVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.55).delay(0.12), value: contentVisible)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red.opacity(0.95))
                                .multilineTextAlignment(.center)
                                .padding(.top, 14)
                                .frame(maxWidth: 360)
                        }

                        Spacer(minLength: isCompact ? 14 : 28)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, isCompact ? 18 : 28)
                }
            }
        }
        .onAppear { contentVisible = true }
    }
}

struct AndroidHomeWallpaper: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.01, green: 0.01, blue: 0.02),
                        Color(red: 0.04, green: 0.04, blue: 0.04),
                        Color(red: 0.03, green: 0.03, blue: 0.07)
                    ]),
                    startPoint: CGPoint(x: size.width * 0.5, y: 0),
                    endPoint: CGPoint(x: size.width * 0.5, y: size.height)
                )
            )

            let gridColor = Color.white.opacity(0.024)
            let step = min(size.width, size.height) / 6
            var x = step
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(gridColor), lineWidth: 1)
                x += step
            }

            var y = step
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(gridColor), lineWidth: 1)
                y += step
            }

            drawGlow(
                context: context,
                size: size,
                center: CGPoint(x: size.width * 0.72, y: size.height * 0.24),
                radius: min(size.width, size.height) * 0.42,
                colors: [
                    Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.32),
                    Color(red: 0.15, green: 0.09, blue: 0.33).opacity(0.22),
                    .clear
                ]
            )

            let lensCenter = CGPoint(x: size.width * 0.72, y: size.height * 0.24)
            for index in 0..<4 {
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: lensCenter.x - min(size.width, size.height) * (0.12 + CGFloat(index) * 0.07),
                        y: lensCenter.y - min(size.width, size.height) * (0.12 + CGFloat(index) * 0.07),
                        width: min(size.width, size.height) * (0.24 + CGFloat(index) * 0.14),
                        height: min(size.width, size.height) * (0.24 + CGFloat(index) * 0.14)
                    )),
                    with: .color(.white.opacity(0.034 + Double(index) * 0.01)),
                    lineWidth: 1.2
                )
            }

            drawGlow(
                context: context,
                size: size,
                center: CGPoint(x: size.width * 0.16, y: size.height * 0.80),
                radius: min(size.width, size.height) * 0.48,
                colors: [
                    Color(red: 0.61, green: 0.43, blue: 1.0).opacity(0.24),
                    Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.10),
                    .clear
                ]
            )
        }
        .ignoresSafeArea()
    }

    private func drawGlow(context: GraphicsContext, size: CGSize, center: CGPoint, radius: CGFloat, colors: [Color]) {
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(Gradient(colors: colors), center: center, startRadius: 0, endRadius: radius)
        )
    }
}

private struct HomeActionCard: View {
    enum Style {
        case primary
        case secondary
    }

    let icon: AndroidLandingFeatureIcon.Kind
    let title: String
    let subtitle: String
    let style: Style
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 42, height: 42)
                } else {
                    AndroidLandingFeatureIcon(kind: icon)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.72))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(">")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color(red: 0.61, green: 0.43, blue: 1.0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(borderColor.opacity(0.62), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var background: LinearGradient {
        switch style {
        case .primary:
            return LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.08, blue: 0.24).opacity(0.92),
                    Color(red: 0.08, green: 0.08, blue: 0.12).opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            return LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.09, blue: 0.13).opacity(0.94),
                    Color(red: 0.06, green: 0.06, blue: 0.09).opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return Color(red: 0.49, green: 0.30, blue: 1.0)
        case .secondary:
            return Color(red: 0.61, green: 0.43, blue: 1.0)
        }
    }
}

struct AppLogoMark: View {
    let size: CGFloat

    var body: some View {
        AndroidPurpleCameraLogo()
            .frame(width: size, height: size)
    }
}

struct PrimaryCameraActionButton: View {
    let title: String
    let systemName: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 18, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.61, green: 0.43, blue: 1.0),
                        Color(red: 0.49, green: 0.30, blue: 1.0),
                        Color(red: 0.29, green: 0.13, blue: 0.72)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: Color.purple.opacity(0.34), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }
}
