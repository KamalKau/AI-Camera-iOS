import SwiftUI

struct AndroidLandingScreen: View {
    let onFinished: () -> Void

    @State private var contentVisible = false
    @State private var featureIndex = 0
    @State private var featureTask: Task<Void, Never>?

    private let features = AndroidLandingFeature.defaultFeatures

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 720
            let logoSize: CGFloat = isCompact ? 88 : 118
            let titleSize: CGFloat = isCompact ? 24 : 28
            let horizontalPadding = min(max(20, geometry.size.width * 0.06), 28)

            ZStack {
                AndroidLandingBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: isCompact ? 24 : 42)

                        VStack(spacing: isCompact ? 16 : 24) {
                            AndroidPurpleCameraLogo()
                                .frame(width: logoSize, height: logoSize)
                                .scaleEffect(contentVisible ? 1 : 0.84)
                                .opacity(contentVisible ? 1 : 0)
                                .animation(.easeOut(duration: 0.64), value: contentVisible)

                            VStack(spacing: 10) {
                                Text("AI Camera Assistant")
                                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.82)

                                Text("Turn any phone into your remote camera controller")
                                    .font(.system(size: isCompact ? 14 : 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .frame(maxWidth: min(310, geometry.size.width - horizontalPadding * 2))
                            }
                            .offset(y: contentVisible ? 0 : 18)
                            .opacity(contentVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.7).delay(0.12), value: contentVisible)
                        }

                        Spacer(minLength: isCompact ? 18 : 28)

                        AndroidLandingFeatureShowcase(
                            features: features,
                            featureIndex: featureIndex,
                            onMove: moveFeature,
                            onSelect: setFeature
                        )
                        .frame(maxWidth: 430)
                        .offset(y: contentVisible ? 0 : 20)
                        .opacity(contentVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.76).delay(0.24), value: contentVisible)

                        Spacer(minLength: isCompact ? 18 : 28)

                        VStack(spacing: 14) {
                            AndroidLandingSwipeIndicator(
                                featureIndex: featureIndex,
                                featureCount: features.count,
                                onSelect: setFeature
                            )

                            AndroidLandingNextButton(text: "Next") {
                                finish()
                            }
                        }
                        .frame(maxWidth: 430)
                        .offset(y: contentVisible ? 0 : 24)
                        .opacity(contentVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.8).delay(0.34), value: contentVisible)
                        .padding(.bottom, isCompact ? 18 : 28)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
        .onAppear {
            contentVisible = true
            scheduleNextFeature()
        }
        .onDisappear {
            featureTask?.cancel()
            featureTask = nil
        }
    }

    private func setFeature(_ index: Int) {
        guard features.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.26)) {
            featureIndex = index
        }
        scheduleNextFeature()
    }

    private func moveFeature(_ delta: Int) {
        let nextIndex = featureIndex + delta
        if nextIndex >= features.count {
            finish()
        } else if nextIndex < 0 {
            setFeature(0)
        } else {
            setFeature(nextIndex)
        }
    }

    private func scheduleNextFeature() {
        featureTask?.cancel()
        featureTask = Task {
            try? await Task.sleep(for: .seconds(1.9))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if featureIndex < features.count - 1 {
                    withAnimation(.easeInOut(duration: 0.26)) {
                        featureIndex += 1
                    }
                    scheduleNextFeature()
                } else {
                    finish()
                }
            }
        }
    }

    private func finish() {
        featureTask?.cancel()
        featureTask = nil
        onFinished()
    }
}

private struct AndroidLandingFeature: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let icon: AndroidLandingFeatureIcon.Kind

    static let defaultFeatures: [AndroidLandingFeature] = [
        AndroidLandingFeature(
            id: "remote",
            title: "Remote Camera Control",
            subtitle: "Full control from your second device",
            icon: .remote
        ),
        AndroidLandingFeature(
            id: "record",
            title: "Remote Video Recording",
            subtitle: "Start and stop recording remotely",
            icon: .record
        ),
        AndroidLandingFeature(
            id: "portrait",
            title: "Portrait Mode",
            subtitle: "Beautiful background blur remotely",
            icon: .portrait
        ),
        AndroidLandingFeature(
            id: "hdrNight",
            title: "HDR Support",
            subtitle: "Better dynamic range and details",
            icon: .hdrNight
        ),
        AndroidLandingFeature(
            id: "scene",
            title: "AI Scene Detection",
            subtitle: "Smart optimization for every scene",
            icon: .scene
        )
    ]
}

private struct AndroidLandingFeatureShowcase: View {
    let features: [AndroidLandingFeature]
    let featureIndex: Int
    let onMove: (Int) -> Void
    let onSelect: (Int) -> Void

    @State private var dragOffset: CGFloat = 0

    private var selectedFeature: AndroidLandingFeature {
        features[featureIndex.clamped(to: features.indices)]
    }

    var body: some View {
        AndroidLandingFeaturePill(feature: selectedFeature)
            .id(selectedFeature.id)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                )
            )
            .animation(.easeInOut(duration: 0.26), value: selectedFeature)
            .offset(x: dragOffset * 0.18)
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        if value.translation.width < -64 {
                            onMove(1)
                        } else if value.translation.width > 64 {
                            onMove(-1)
                        }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            dragOffset = 0
                        }
                    }
            )
            .onTapGesture {
                onSelect((featureIndex + 1) % features.count)
            }
    }
}

private struct AndroidLandingFeaturePill: View {
    let feature: AndroidLandingFeature

    var body: some View {
        HStack(spacing: 12) {
            AndroidLandingFeatureIcon(kind: feature.icon)

            VStack(alignment: .leading, spacing: 5) {
                Text(feature.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(feature.subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.13).opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

struct AndroidLandingFeatureIcon: View {
    enum Kind {
        case remote
        case record
        case portrait
        case hdrNight
        case scene
    }

    let kind: Kind

    private var backgroundColor: Color {
        switch kind {
        case .portrait:
            return Color(red: 1.0, green: 0.78, blue: 0.27).opacity(0.82)
        case .hdrNight:
            return Color(red: 0.13, green: 0.71, blue: 0.44).opacity(0.82)
        case .scene:
            return Color(red: 0.18, green: 0.49, blue: 1.0).opacity(0.82)
        case .remote, .record:
            return Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.82)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundColor)

            Canvas { context, size in
                drawIcon(kind, context: context, size: size)
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 42, height: 42)
    }

    private func drawIcon(_ kind: Kind, context: GraphicsContext, size: CGSize) {
        let white = Color.white
        let purple = Color(red: 0.78, green: 0.71, blue: 1.0)
        let minDimension = min(size.width, size.height)
        let stroke = minDimension * 0.08

        switch kind {
        case .remote:
            context.stroke(
                Path(roundedRect: CGRect(x: size.width * 0.1, y: size.height * 0.25, width: size.width * 0.8, height: size.height * 0.48), cornerRadius: 6),
                with: .color(white),
                lineWidth: stroke
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: size.width * 0.35, y: size.height * 0.35, width: size.width * 0.3, height: size.height * 0.3)),
                with: .color(purple),
                lineWidth: minDimension * 0.07
            )
            var line = Path()
            line.move(to: CGPoint(x: size.width * 0.22, y: size.height * 0.1))
            line.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.1))
            context.stroke(line, with: .color(purple), lineWidth: minDimension * 0.07)
        case .record:
            context.stroke(
                Path(roundedRect: CGRect(x: size.width * 0.08, y: size.height * 0.25, width: size.width * 0.62, height: size.height * 0.5), cornerRadius: 6),
                with: .color(white),
                lineWidth: stroke
            )
            var camera = Path()
            camera.move(to: CGPoint(x: size.width * 0.72, y: size.height * 0.42))
            camera.addLine(to: CGPoint(x: size.width * 0.94, y: size.height * 0.3))
            camera.addLine(to: CGPoint(x: size.width * 0.94, y: size.height * 0.7))
            camera.addLine(to: CGPoint(x: size.width * 0.72, y: size.height * 0.58))
            camera.closeSubpath()
            context.fill(camera, with: .color(white))
            context.fill(
                Path(ellipseIn: CGRect(x: size.width * 0.26, y: size.height * 0.38, width: size.width * 0.24, height: size.height * 0.24)),
                with: .color(Color(red: 1.0, green: 0.31, blue: 0.43))
            )
        case .portrait:
            context.stroke(
                Path(ellipseIn: CGRect(x: size.width * 0.34, y: size.height * 0.18, width: size.width * 0.32, height: size.height * 0.32)),
                with: .color(purple),
                lineWidth: stroke
            )
            context.stroke(
                Path(roundedRect: CGRect(x: size.width * 0.28, y: size.height * 0.56, width: size.width * 0.44, height: size.height * 0.25), cornerRadius: 18),
                with: .color(white),
                lineWidth: stroke
            )
            context.stroke(
                Path(roundedRect: CGRect(x: size.width * 0.08, y: size.height * 0.1, width: size.width * 0.84, height: size.height * 0.8), cornerRadius: 9),
                with: .color(purple),
                lineWidth: minDimension * 0.045
            )
        case .scene:
            context.stroke(
                Path(roundedRect: CGRect(x: size.width * 0.18, y: size.height * 0.18, width: size.width * 0.64, height: size.height * 0.64), cornerRadius: 7),
                with: .color(white),
                lineWidth: stroke
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: size.width * 0.36, y: size.height * 0.36, width: size.width * 0.28, height: size.height * 0.28)),
                with: .color(purple),
                lineWidth: minDimension * 0.07
            )
            drawLine(context: context, size: size, from: CGPoint(x: 0.5, y: 0.08), to: CGPoint(x: 0.5, y: 0.22), color: white)
            drawLine(context: context, size: size, from: CGPoint(x: 0.5, y: 0.78), to: CGPoint(x: 0.5, y: 0.92), color: white)
            drawLine(context: context, size: size, from: CGPoint(x: 0.08, y: 0.5), to: CGPoint(x: 0.22, y: 0.5), color: white)
            drawLine(context: context, size: size, from: CGPoint(x: 0.78, y: 0.5), to: CGPoint(x: 0.92, y: 0.5), color: white)
        case .hdrNight:
            context.fill(
                Path(ellipseIn: CGRect(x: size.width * 0.2, y: size.height * 0.2, width: size.width * 0.48, height: size.height * 0.48)),
                with: .color(purple)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: size.width * 0.3, y: size.height * 0.12, width: size.width * 0.48, height: size.height * 0.48)),
                with: .color(Color(red: 0.18, green: 0.11, blue: 0.43))
            )
            drawLine(context: context, size: size, from: CGPoint(x: 0.18, y: 0.76), to: CGPoint(x: 0.82, y: 0.76), color: white)
            context.fill(
                Path(ellipseIn: CGRect(x: size.width * 0.725, y: size.height * 0.185, width: size.width * 0.11, height: size.height * 0.11)),
                with: .color(white)
            )
        }
    }

    private func drawLine(context: GraphicsContext, size: CGSize, from: CGPoint, to: CGPoint, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: size.width * from.x, y: size.height * from.y))
        path.addLine(to: CGPoint(x: size.width * to.x, y: size.height * to.y))
        context.stroke(path, with: .color(color), lineWidth: min(size.width, size.height) * 0.055)
    }
}

private struct AndroidLandingSwipeIndicator: View {
    let featureIndex: Int
    let featureCount: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<featureCount, id: \.self) { index in
                    Button {
                        onSelect(index)
                    } label: {
                        Capsule()
                            .fill(index == featureIndex ? Color(red: 0.49, green: 0.30, blue: 1.0) : .white.opacity(0.28))
                            .frame(width: index == featureIndex ? 22 : 8, height: 8)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(featureIndex == featureCount - 1 ? "Swipe left to continue" : "Swipe to explore")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 10)
    }
}

private struct AndroidLandingNextButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(text) >")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
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
        }
        .buttonStyle(.plain)
    }
}

struct CameraWelcomeBackground: View {
    var showsFramingLines = true

    var body: some View {
        ZStack {
            Image("AndroidWelcomeWallpaper")
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.11, blue: 0.43).opacity(0.44),
                    Color(red: 0.10, green: 0.06, blue: 0.22).opacity(0.50),
                    .black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.14)

            if showsFramingLines {
                GeometryReader { geometry in
                    CameraFramingLines()
                        .stroke(.white.opacity(0.16), lineWidth: 1.2)
                        .frame(width: min(geometry.size.width - 54, 330), height: min(geometry.size.height * 0.42, 410))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.35)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct AndroidLandingBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04)

            RadialGradient(
                colors: [
                    Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.28),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 20,
                endRadius: 260
            )

            RadialGradient(
                colors: [
                    Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.20),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.88),
                startRadius: 10,
                endRadius: 250
            )

            LinearGradient(
                colors: [
                    .black.opacity(0.08),
                    .black.opacity(0.42),
                    .black.opacity(0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct CameraFramingLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner: CGFloat = 30
        let length: CGFloat = 48

        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))

        return path
    }
}

struct AndroidPurpleCameraLogo: View {
    var body: some View {
        Canvas { context, size in
            let minDimension = min(size.width, size.height)
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let corner = minDimension * 0.25

            context.fill(
                Path(roundedRect: rect, cornerRadius: corner * 1.08),
                with: .color(.black.opacity(0.86))
            )

            let glow = Gradient(colors: [
                Color(red: 0.49, green: 0.30, blue: 1.0).opacity(0.48),
                .clear
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - minDimension * 0.72,
                    y: center.y - minDimension * 0.72,
                    width: minDimension * 1.44,
                    height: minDimension * 1.44
                )),
                with: .radialGradient(glow, center: center, startRadius: 0, endRadius: minDimension * 0.72)
            )

            let iconGradient = Gradient(colors: [
                Color(red: 0.90, green: 0.87, blue: 1.0),
                Color(red: 0.72, green: 0.61, blue: 1.0),
                Color(red: 0.49, green: 0.30, blue: 1.0),
                Color(red: 0.30, green: 0.15, blue: 0.78)
            ])
            context.fill(
                Path(roundedRect: rect, cornerRadius: corner),
                with: .linearGradient(iconGradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: size.height))
            )

            let insetRect = CGRect(
                x: size.width * 0.06,
                y: size.height * 0.06,
                width: size.width * 0.88,
                height: size.height * 0.88
            )
            context.stroke(
                Path(roundedRect: insetRect, cornerRadius: minDimension * 0.22),
                with: .color(.black.opacity(0.18)),
                lineWidth: minDimension * 0.045
            )

            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - minDimension * 0.19,
                    y: center.y - minDimension * 0.19,
                    width: minDimension * 0.38,
                    height: minDimension * 0.38
                )),
                with: .color(.white.opacity(0.96)),
                lineWidth: minDimension * 0.052
            )

            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - minDimension * 0.105,
                    y: center.y - minDimension * 0.105,
                    width: minDimension * 0.21,
                    height: minDimension * 0.21
                )),
                with: .color(.black.opacity(0.34))
            )

            let highlightCenter = CGPoint(x: size.width * 0.7, y: size.height * 0.29)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: highlightCenter.x - minDimension * 0.055,
                    y: highlightCenter.y - minDimension * 0.055,
                    width: minDimension * 0.11,
                    height: minDimension * 0.11
                )),
                with: .color(.white.opacity(0.92))
            )
        }
        .shadow(color: Color(red: 0.48, green: 0.30, blue: 1.0).opacity(0.42), radius: 26, x: 0, y: 14)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        guard let lower = range.min(), let upper = range.max() else { return self }
        return Swift.min(Swift.max(self, lower), upper)
    }
}
