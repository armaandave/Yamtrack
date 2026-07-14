import XCTest
@testable import Spine

@MainActor
final class SpineMotionTests: XCTestCase {
    func testAppearanceStateStartsConcealed() {
        let appearance = SpineAppearanceState()

        XCTAssertFalse(appearance.isRevealed)
        XCTAssertEqual(appearance.opacity, 0)
    }

    func testAppearanceStateRevealMakesSurfaceOpaque() {
        var appearance = SpineAppearanceState()

        appearance.reveal()

        XCTAssertTrue(appearance.isRevealed)
        XCTAssertEqual(appearance.opacity, 1)
    }

    func testAppearanceStateRevealIsIdempotent() {
        var appearance = SpineAppearanceState()
        appearance.reveal()
        let revealedAppearance = appearance

        appearance.reveal()

        XCTAssertEqual(appearance, revealedAppearance)
    }

    func testStandardDurationIsBriefAndPositive() {
        XCTAssertGreaterThan(SpineMotion.standardDuration, 0)
        XCTAssertLessThanOrEqual(SpineMotion.standardDuration, 0.25)
        XCTAssertEqual(
            SpineMotion.durations(reduceMotion: false),
            SpineMotion.standardDuration
        )
    }

    func testReduceMotionUsesABriefOpacityDissolve() {
        XCTAssertGreaterThan(SpineMotion.reducedDuration, 0)
        XCTAssertLessThan(SpineMotion.reducedDuration, SpineMotion.standardDuration)
        XCTAssertLessThanOrEqual(SpineMotion.reducedDuration, 0.25)
        XCTAssertEqual(
            SpineMotion.durations(reduceMotion: true),
            SpineMotion.reducedDuration
        )
    }

    func testContentPhaseResolvesInitialLoading() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: true,
                hasContent: false,
                hasError: false
            ),
            .loading
        )
    }

    func testContentPhaseResolvesErrorWithoutContent() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: false,
                hasContent: false,
                hasError: true
            ),
            .error
        )
    }

    func testContentPhaseResolvesEmptyWhenIdleWithoutContentOrError() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: false,
                hasContent: false,
                hasError: false
            ),
            .empty
        )
    }

    func testContentPhaseResolvesLoadedContent() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: false,
                hasContent: true,
                hasError: false
            ),
            .content
        )
    }

    func testContentPhasePreservesLoadedContentWhileRefreshing() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: true,
                hasContent: true,
                hasError: false
            ),
            .content
        )
    }

    func testContentPhasePreservesLoadedContentWhileErroring() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: false,
                hasContent: true,
                hasError: true
            ),
            .content
        )
    }

    func testContentPhasePreservesLoadedContentWhenRefreshAlsoErrors() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: true,
                hasContent: true,
                hasError: true
            ),
            .content
        )
    }

    func testLoadingTakesPrecedenceOverErrorWithoutContent() {
        XCTAssertEqual(
            SpineContentPhase.resolve(
                isLoading: true,
                hasContent: false,
                hasError: true
            ),
            .loading
        )
    }
}
