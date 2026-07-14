import SwiftUI

struct RootView: View {
    @State private var session: AppSession

    init(repositories: AppRepositories = .current()) {
        _session = State(initialValue: AppSession(repositories: repositories))
    }

    var body: some View {
        Group {
            switch session.state {
            case .checking:
                ProgressView("Checking session")
            case .signedOut:
                AuthView(session: session)
            case .signedIn:
                AppShellView(session: session)
            }
        }
        .spineContentTransition(value: presentationPhase)
        .task {
            await session.start()
        }
    }

    private var presentationPhase: RootPresentationPhase {
        switch session.state {
        case .checking: .checking
        case .signedOut: .signedOut
        case .signedIn: .signedIn
        }
    }
}

private enum RootPresentationPhase: Hashable {
    case checking
    case signedOut
    case signedIn
}

#Preview {
    RootView()
}
