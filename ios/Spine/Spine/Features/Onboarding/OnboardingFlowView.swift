import SwiftUI

struct OnboardingFlowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: AppSession
    let store: OnboardingStore

    @State private var authMode: AuthView.Mode
    @State private var isShowingAuth: Bool

    init(session: AppSession, store: OnboardingStore) {
        self.session = session
        self.store = store
        _authMode = State(initialValue: store.preferredAuthMode)
        _isShowingAuth = State(initialValue: store.hasSeenWelcome)
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            if isShowingAuth {
                AuthView(session: session, initialMode: authMode)
                    .transition(flowTransition)
            } else {
                OnboardingWelcomeView(
                    onCreateAccount: { showAuth(.register) },
                    onSignIn: { showAuth(.login) }
                )
                .transition(flowTransition)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var flowTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .scale(scale: 0.97).combined(with: .opacity)
        )
    }

    private func showAuth(_ mode: AuthView.Mode) {
        authMode = mode
        store.markWelcomeSeen(preferredAuthMode: mode)
        withAnimation(SpineMotion.animation(reduceMotion: reduceMotion)) {
            isShowingAuth = true
        }
    }
}

private struct OnboardingWelcomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onCreateAccount: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    SpineWordmark()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 16 : 24)

                    if !dynamicTypeSize.isAccessibilitySize {
                        OnboardingMediaMosaic()
                            .frame(height: heroHeight(for: proxy.size.height))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Movies, television, anime, manga, games, books, comics, and board games")

                        Spacer(minLength: 28)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your whole media life,\nin one place.")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Track what you watch, read, and play — and discover what’s next.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 28)

                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            Button(action: onCreateAccount) {
                                Text("Create account")
                                    .font(.headline)
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .tint(.white)
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("onboarding.createAccount")

                            Button(action: onSignIn) {
                                Text("Sign in")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .tint(.white.opacity(0.12))
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("onboarding.signIn")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 18)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
    }

    private func heroHeight(for availableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 190
        }
        return min(310, max(240, availableHeight * 0.37))
    }
}

struct SpineWordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            SpineMark()
                .frame(width: 24, height: 24)

            Text("SPINE")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .tracking(3.2)
                .foregroundStyle(.white.opacity(0.9))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spine")
    }
}

private struct SpineMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            Capsule()
                .frame(width: 4, height: 15)
                .rotationEffect(.degrees(-7))
            Capsule()
                .frame(width: 4, height: 21)
            Capsule()
                .frame(width: 4, height: 17)
                .rotationEffect(.degrees(6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.75)
        }
    }
}

struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            SpinePalette.pageBackground

            RadialGradient(
                colors: [Color(red: 0.28, green: 0.18, blue: 0.48).opacity(0.34), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 430
            )

            RadialGradient(
                colors: [Color(red: 0.12, green: 0.35, blue: 0.39).opacity(0.24), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 390
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingMediaMosaic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 350, proxy.size.height / 300)

            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.20))
                    .frame(width: 220, height: 220)
                    .blur(radius: 55)

                poster("TV", symbol: "tv.fill", colors: [.indigo, .black], width: 100, height: 150)
                    .onboardingCardEntrance(
                        isRevealed: isRevealed,
                        reduceMotion: reduceMotion,
                        rotation: -14,
                        x: -112,
                        y: -34,
                        scale: 0.88,
                        delay: 0.02
                    )

                poster("BOOKS", symbol: "book.closed.fill", colors: [.orange, .red.opacity(0.58)], width: 100, height: 150)
                    .onboardingCardEntrance(
                        isRevealed: isRevealed,
                        reduceMotion: reduceMotion,
                        rotation: 13,
                        x: 110,
                        y: -42,
                        scale: 0.86,
                        delay: 0.06
                    )

                poster("MANGA", symbol: "text.book.closed.fill", colors: [.pink.opacity(0.76), .purple.opacity(0.56)], width: 104, height: 156)
                    .onboardingCardEntrance(
                        isRevealed: isRevealed,
                        reduceMotion: reduceMotion,
                        rotation: -8,
                        x: -90,
                        y: 72,
                        scale: 0.94,
                        delay: 0.10
                    )

                poster("GAMES", symbol: "gamecontroller.fill", colors: [.teal, .blue.opacity(0.55)], width: 104, height: 156)
                    .onboardingCardEntrance(
                        isRevealed: isRevealed,
                        reduceMotion: reduceMotion,
                        rotation: 9,
                        x: 94,
                        y: 68,
                        scale: 0.93,
                        delay: 0.14
                    )

                poster("SPINE", symbol: "square.stack.3d.up.fill", colors: [.white.opacity(0.36), .black], width: 132, height: 198)
                    .onboardingCardEntrance(
                        isRevealed: isRevealed,
                        reduceMotion: reduceMotion,
                        rotation: 0,
                        x: 0,
                        y: 12,
                        scale: 1,
                        delay: 0.18
                    )
            }
            .frame(width: 350, height: 300)
            .scaleEffect(scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            isRevealed = true
        }
    }

    private func poster(
        _ label: String,
        symbol: String,
        colors: [Color],
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        OnboardingPosterCard(
            label: label,
            symbol: symbol,
            colors: colors,
            width: width,
            height: height
        )
    }
}

private struct OnboardingPosterCard: View {
    let label: String
    let symbol: String
    let colors: [Color]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: width * 0.9, height: width * 0.9)
                .blur(radius: 22)
                .offset(x: width * 0.28, y: -height * 0.28)

            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: width * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(label)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.78))
                .padding(12)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.42), radius: 18, y: 10)
    }
}

private struct OnboardingCardEntranceModifier: ViewModifier {
    let isRevealed: Bool
    let reduceMotion: Bool
    let rotation: Double
    let x: CGFloat
    let y: CGFloat
    let finalScale: CGFloat
    let delay: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: isRevealed ? y : y + 20)
            .scaleEffect(isRevealed ? finalScale : finalScale * 0.92)
            .opacity(isRevealed ? 1 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82).delay(delay),
                value: isRevealed
            )
    }
}

private extension View {
    func onboardingCardEntrance(
        isRevealed: Bool,
        reduceMotion: Bool,
        rotation: Double,
        x: CGFloat,
        y: CGFloat,
        scale: CGFloat,
        delay: Double
    ) -> some View {
        modifier(OnboardingCardEntranceModifier(
            isRevealed: isRevealed,
            reduceMotion: reduceMotion,
            rotation: rotation,
            x: x,
            y: y,
            finalScale: scale,
            delay: delay
        ))
    }
}

#Preview("First launch") {
    OnboardingFlowView(
        session: AppSession(repositories: .live()),
        store: OnboardingStore(defaults: UserDefaults(suiteName: "OnboardingPreview") ?? .standard)
    )
}
