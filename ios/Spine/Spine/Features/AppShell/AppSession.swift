import Foundation

@MainActor
@Observable
final class AppSession {
    enum State {
        case checking
        case signedOut
        case signedIn(AuthUser?)
    }

    enum SignedInEntryPoint: Equatable {
        case home
        case search
    }

    var state: State = .checking
    var errorMessage: String?
    private(set) var signedInEntryPoint: SignedInEntryPoint = .home

    let repositories: AppRepositories
    let letterboxdImportCoordinator: LetterboxdImportCoordinator
    let storygraphImportCoordinator: StoryGraphImportCoordinator
    let goodreadsImportCoordinator: GoodreadsImportCoordinator

    init(repositories: AppRepositories) {
        self.repositories = repositories
        self.letterboxdImportCoordinator = LetterboxdImportCoordinator(importRepository: repositories.imports)
        self.storygraphImportCoordinator = StoryGraphImportCoordinator(importRepository: repositories.imports)
        self.goodreadsImportCoordinator = GoodreadsImportCoordinator(importRepository: repositories.imports)
        self.letterboxdImportCoordinator.onUnauthorized = { [weak self] in
            Task { await self?.logout() }
        }
        self.storygraphImportCoordinator.onUnauthorized = { [weak self] in
            Task { await self?.logout() }
        }
        self.goodreadsImportCoordinator.onUnauthorized = { [weak self] in
            Task { await self?.logout() }
        }
    }

    func start() async {
        guard repositories.auth.hasStoredTokens else {
            signedInEntryPoint = .home
            state = .signedOut
            return
        }

        do {
            try await repositories.auth.refresh()
            let profile = try? await repositories.profile.me()
            signedInEntryPoint = .home
            state = .signedIn(profile.map(AuthUser.init(profile:)))
            letterboxdImportCoordinator.resumeIfNeeded()
            storygraphImportCoordinator.resumeIfNeeded()
            goodreadsImportCoordinator.resumeIfNeeded()
        } catch {
            await repositories.auth.logout()
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func login(usernameOrEmail: String, password: String) async {
        errorMessage = nil
        do {
            let user = try await repositories.auth.login(usernameOrEmail: usernameOrEmail, password: password)
            signedInEntryPoint = .home
            state = .signedIn(user)
            letterboxdImportCoordinator.resumeIfNeeded()
            storygraphImportCoordinator.resumeIfNeeded()
            goodreadsImportCoordinator.resumeIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func register(username: String, email: String, password: String) async {
        errorMessage = nil
        do {
            let user = try await repositories.auth.register(username: username, email: email, password: password)
            signedInEntryPoint = .search
            state = .signedIn(user)
            letterboxdImportCoordinator.resumeIfNeeded()
            storygraphImportCoordinator.resumeIfNeeded()
            goodreadsImportCoordinator.resumeIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() async {
        await repositories.auth.logout()
        letterboxdImportCoordinator.clearFinishedJob()
        storygraphImportCoordinator.clearFinishedJob()
        goodreadsImportCoordinator.clearFinishedJob()
        signedInEntryPoint = .home
        errorMessage = nil
        state = .signedOut
    }

    func clearError() {
        errorMessage = nil
    }

    func markSignedInEntryPointHandled() {
        signedInEntryPoint = .home
    }
}

private extension AuthUser {
    init(profile: UserProfile) {
        self.init(id: profile.id, username: profile.username, displayName: profile.displayName, isPrivate: profile.isPrivate)
    }
}
