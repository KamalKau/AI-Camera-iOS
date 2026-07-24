import SwiftUI

struct AndroidWelcomeScreen: View {
    let onContinue: () -> Void

    @State private var logoVisible = false
    @State private var titleVisible = false
    @State private var buttonsVisible = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isCompact = geometry.size.height < 720
            let safeHeight = geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom
            let horizontalPadding = min(max(20, geometry.size.width * 0.055), 28)
            let columnWidth = min(390, max(240, geometry.size.width - horizontalPadding * 2))
            let logoSize: CGFloat = isLandscape ? 40 : (isCompact ? 50 : 62)
            let titleSize: CGFloat = isLandscape ? 20 : (isCompact ? 23 : 26)
            let buttonHeight: CGFloat = (isLandscape || isCompact) ? 44 : 54
            let topPadding: CGFloat = isLandscape ? 18 : (isCompact ? 18 : 30)
            let gap: CGFloat = isLandscape ? 14 : (isCompact ? 18 : 28)
            let scrollContentHeight = isLandscape ? max(540, geometry.size.height + 180) : max(safeHeight, 1)
            let bottomPadding: CGFloat = isLandscape ? 96 : max(34, geometry.safeAreaInsets.bottom + 18)

            ZStack(alignment: .center) {
                Color.black
                    .ignoresSafeArea()

                CameraWelcomeBackground(showsFramingLines: false)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        .black.opacity(0.18),
                        .black.opacity(0.42),
                        Color(red: 0.04, green: 0.04, blue: 0.04).opacity(0.98)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: gap) {
                        header(logoSize: logoSize, titleSize: titleSize, isCompact: isLandscape || isCompact)
                            .frame(width: columnWidth, alignment: .center)
                            .padding(.top, topPadding)

                        actionButtons(height: buttonHeight, width: columnWidth)

                        Color.clear.frame(height: bottomPadding)
                    }
                    .frame(width: geometry.size.width, alignment: .center)
                    .frame(minHeight: scrollContentHeight, alignment: isLandscape ? .top : .center)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color.clear)
                .scrollBounceBehavior(.always)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .onAppear {
            logoVisible = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                titleVisible = true
                try? await Task.sleep(for: .milliseconds(220))
                buttonsVisible = true
            }
        }
    }

    private func header(logoSize: CGFloat, titleSize: CGFloat, isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            AndroidPurpleCameraLogo()
                .frame(width: logoSize, height: logoSize)
                .scaleEffect(logoVisible ? 1 : 0.80)
                .opacity(logoVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.62), value: logoVisible)

            VStack(spacing: 2) {
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
                                Color(red: 0.89, green: 0.85, blue: 1.0),
                                Color(red: 0.49, green: 0.30, blue: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("Turn any phone into your\nremote camera controller")
                    .font(.system(size: isCompact ? 12 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 10)
            }
            .padding(.top, isCompact ? 8 : 12)
            .offset(y: titleVisible ? 0 : 12)
            .opacity(titleVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.36), value: titleVisible)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func actionButtons(height: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 10) {
            AndroidWelcomeButton(
                title: "Continue with Google",
                leading: .text("G"),
                style: .primary,
                height: height,
                action: onContinue
            )

            AndroidWelcomeButton(
                title: "Continue with Apple",
                leading: .systemImage("apple.logo"),
                style: .primary,
                height: height,
                action: onContinue
            )

            AndroidWelcomeButton(
                title: "Continue as Guest",
                leading: .systemImage("person"),
                style: .secondary,
                height: height,
                action: onContinue
            )

            VStack(spacing: 2) {
                Text("By continuing, you agree to our")
                    .foregroundStyle(.white.opacity(0.48))
                Text("Terms of Service   Privacy Policy")
                    .foregroundStyle(Color(red: 0.78, green: 0.71, blue: 1.0))
                    .fontWeight(.semibold)
            }
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .padding(.top, 2)
        }
        .frame(width: width, alignment: .center)
        .offset(y: buttonsVisible ? 0 : 6)
        .opacity(buttonsVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.30), value: buttonsVisible)
    }
}

private struct AndroidWelcomeButton: View {
    enum Style {
        case primary
        case secondary
    }

    enum Leading {
        case text(String)
        case systemImage(String)
    }

    let title: String
    let leading: Leading
    let style: Style
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leadingView
                    .frame(width: 28, height: 28)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .frame(maxWidth: .infinity, alignment: .center)

                Color.clear.frame(width: 28, height: 28)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .text(let text):
            Text(text)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
        case .systemImage(let name):
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .black
        case .secondary:
            return .white
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .white.opacity(0.50)
        case .secondary:
            return Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.28)
        }
    }

    private var background: LinearGradient {
        switch style {
        case .primary:
            return LinearGradient(
                colors: [.white, Color(red: 0.95, green: 0.94, blue: 0.98)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .secondary:
            return LinearGradient(
                colors: [.black.opacity(0.58), .black.opacity(0.36)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
