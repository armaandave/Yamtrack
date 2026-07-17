import XCTest
@testable import Spine

@MainActor
final class MediaRatingPickerStateTests: XCTestCase {
    func testDraftDismissalAndLocalConfirmation() {
        var state = MediaRatingPickerState()

        state.open()
        XCTAssertTrue(state.isPresented)
        XCTAssertTrue(state.hasLocallyWatched)
        XCTAssertFalse(state.showsConfirm)

        state.draftHalfSteps = 7
        XCTAssertTrue(state.showsConfirm)
        state.draftHalfSteps = 0
        XCTAssertFalse(state.showsConfirm)

        state.draftHalfSteps = 7
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.draftHalfSteps, 0)

        state.open()
        state.draftHalfSteps = 7
        state.confirm()
        XCTAssertEqual(state.confirmedHalfSteps, 7)

        state.open()
        XCTAssertEqual(state.draftHalfSteps, 7)
        state.draftHalfSteps = 0
        XCTAssertFalse(state.showsConfirm)
        state.dismiss()
        XCTAssertEqual(state.draftHalfSteps, 7)
    }
}
