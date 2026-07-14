import SwiftUI

enum SpineMotion {
    static let standardDuration = 0.18
    static let reducedDuration = 0.10

    static func durations(reduceMotion: Bool) -> Double {
        reduceMotion ? reducedDuration : standardDuration
    }

    static func animation(reduceMotion: Bool) -> Animation {
        .easeOut(duration: durations(reduceMotion: reduceMotion))
    }
}

struct SpineAppearanceState: Equatable {
    private(set) var isRevealed = false

    var opacity: Double {
        isRevealed ? 1 : 0
    }

    mutating func reveal() {
        isRevealed = true
    }
}

enum SpineContentPhase: Hashable {
    case loading
    case content
    case error
    case empty

    static func resolve(isLoading: Bool, hasContent: Bool, hasError: Bool) -> SpineContentPhase {
        if hasContent {
            return .content
        }
        if isLoading {
            return .loading
        }
        if hasError {
            return .error
        }
        return .empty
    }
}

private struct SpineContentTransitionModifier<Value: Hashable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: Value

    func body(content: Content) -> some View {
        content
            .id(value)
            .transition(.opacity)
            .animation(SpineMotion.animation(reduceMotion: reduceMotion), value: value)
            .spineSoftAppear()
    }
}

private struct SpineAncestorSoftAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var spineAncestorSoftAppearanceActive: Bool {
        get { self[SpineAncestorSoftAppearanceKey.self] }
        set { self[SpineAncestorSoftAppearanceKey.self] = newValue }
    }
}

private struct SpineSoftAppearanceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spineAncestorSoftAppearanceActive) private var ancestorAppearanceActive
    @State private var appearance = SpineAppearanceState()

    func body(content: Content) -> some View {
        content
            .opacity(ancestorAppearanceActive ? 1 : appearance.opacity)
            .environment(
                \.spineAncestorSoftAppearanceActive,
                ancestorAppearanceActive || !appearance.isRevealed
            )
            .onAppear {
                guard !appearance.isRevealed else { return }
                if ancestorAppearanceActive {
                    appearance.reveal()
                } else {
                    withAnimation(SpineMotion.animation(reduceMotion: reduceMotion)) {
                        appearance.reveal()
                    }
                }
            }
    }
}

extension View {
    func spineContentTransition<Value: Hashable>(value: Value) -> some View {
        modifier(SpineContentTransitionModifier(value: value))
    }

    func spineSoftAppear() -> some View {
        modifier(SpineSoftAppearanceModifier())
    }
}

struct SpineAsyncImage<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastSuccessfulImage: Image?

    let url: URL?
    let scale: CGFloat
    private let content: (AsyncImagePhase) -> Content

    init(
        url: URL?,
        scale: CGFloat = 1,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.content = content
    }

    var body: some View {
        AsyncImage(
            url: url,
            scale: scale,
            transaction: Transaction(animation: SpineMotion.animation(reduceMotion: reduceMotion))
        ) { phase in
            resolvedContent(for: phase)
        }
        .id(url)
        .transition(.opacity)
        .animation(SpineMotion.animation(reduceMotion: reduceMotion), value: url)
        .onChange(of: url) { _, newURL in
            if newURL == nil {
                lastSuccessfulImage = nil
            }
        }
    }

    @ViewBuilder
    private func resolvedContent(for phase: AsyncImagePhase) -> some View {
        switch phase {
        case let .success(image):
            content(.success(image))
                .transition(.opacity)
                .onAppear {
                    lastSuccessfulImage = image
                }
        case .empty, .failure:
            if url != nil, let lastSuccessfulImage {
                content(.success(lastSuccessfulImage))
                    .transition(.opacity)
            } else {
                content(phase)
                    .transition(.opacity)
            }
        @unknown default:
            content(phase)
                .transition(.opacity)
        }
    }
}
