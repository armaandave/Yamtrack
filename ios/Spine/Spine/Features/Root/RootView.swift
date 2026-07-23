import SwiftUI

@MainActor
struct RootView: View {
    @State private var session: AppSession
    @State private var onboardingStore: OnboardingStore

    init() {
        self.init(repositories: .current())
    }

    init(
        repositories: AppRepositories,
        onboardingStore: OnboardingStore? = nil
    ) {
        _session = State(initialValue: AppSession(repositories: repositories))
        _onboardingStore = State(initialValue: onboardingStore ?? OnboardingStore())
    }

    var body: some View {
        Group {
            switch session.state {
            case .checking:
                SessionCheckingView()
                    .spineSoftAppear()
            case .signedOut:
                OnboardingFlowView(session: session, store: onboardingStore)
                    .spineSoftAppear()
            case .signedIn:
                AppShellView(session: session)
                    .spineSoftAppear()
            }
        }
        .task {
            await session.start()
            if case .signedIn = session.state {
                onboardingStore.markWelcomeSeen()
            }
        }
    }
}

private struct SessionCheckingView: View {
    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 18) {
                SpineWordmark()
                ProgressView()
                    .tint(.white.opacity(0.72))
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening Spine")
    }
}

#Preview {
    RootView()
}
