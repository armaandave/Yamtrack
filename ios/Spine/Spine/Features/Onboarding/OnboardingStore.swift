import Foundation

@MainActor
@Observable
final class OnboardingStore {
    static let welcomeSeenKey = "spine.onboarding.welcome-seen.v1"
    static let authModeKey = "spine.onboarding.auth-mode.v1"

    private(set) var hasSeenWelcome: Bool
    private(set) var preferredAuthMode: AuthView.Mode

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasSeenWelcome = defaults.bool(forKey: Self.welcomeSeenKey)
        self.preferredAuthMode = AuthView.Mode(
            rawValue: defaults.string(forKey: Self.authModeKey) ?? ""
        ) ?? .login
    }

    func markWelcomeSeen(preferredAuthMode: AuthView.Mode = .login) {
        self.preferredAuthMode = preferredAuthMode
        hasSeenWelcome = true
        defaults.set(true, forKey: Self.welcomeSeenKey)
        defaults.set(preferredAuthMode.rawValue, forKey: Self.authModeKey)
    }
}
