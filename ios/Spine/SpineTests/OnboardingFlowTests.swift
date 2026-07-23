import XCTest
@testable import Spine

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testOnboardingStoreStartsUnseenAndPersistsWelcomeChoice() {
        let defaults = isolatedDefaults()
        let store = OnboardingStore(defaults: defaults)

        XCTAssertFalse(store.hasSeenWelcome)

        store.markWelcomeSeen(preferredAuthMode: .register)

        XCTAssertTrue(store.hasSeenWelcome)
        let restoredStore = OnboardingStore(defaults: defaults)
        XCTAssertTrue(restoredStore.hasSeenWelcome)
        XCTAssertEqual(restoredStore.preferredAuthMode, .register)
    }

    func testLoginValidationTrimsIdentifierAndRequiresPassword() {
        var form = AuthFormValues(usernameOrEmail: "  reader@example.com  ", password: "")

        XCTAssertEqual(form.trimmedUsernameOrEmail, "reader@example.com")
        XCTAssertFalse(form.canSubmit(mode: .login))

        form.password = "secret"

        XCTAssertTrue(form.canSubmit(mode: .login))
    }

    func testRegistrationValidationRequiresIdentityEmailAndEightCharacterPassword() {
        var form = AuthFormValues(
            username: "  reader  ",
            email: "reader@example.com",
            password: "short"
        )

        XCTAssertEqual(form.trimmedUsername, "reader")
        XCTAssertTrue(form.isEmailValid)
        XCTAssertFalse(form.isRegistrationPasswordValid)
        XCTAssertFalse(form.canSubmit(mode: .register))

        form.password = "long-enough"

        XCTAssertTrue(form.canSubmit(mode: .register))
    }

    func testRegistrationValidationRejectsIncompleteEmail() {
        let form = AuthFormValues(
            username: "reader",
            email: "reader.example.com",
            password: "long-enough"
        )

        XCTAssertFalse(form.isEmailValid)
        XCTAssertFalse(form.canSubmit(mode: .register))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
