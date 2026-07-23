import XCTest
@testable import Spine

final class HomeBackdropMotionTests: XCTestCase {
    func testBackdropIsFullyVisibleAtTop() {
        XCTAssertEqual(HomeBackdropMotion.opacity(for: 0), 1)
    }

    func testBackdropFadesAsHomeScrolls() {
        XCTAssertEqual(HomeBackdropMotion.opacity(for: 120), 0.5)
    }

    func testBackdropIsHiddenAfterFadeDistance() {
        XCTAssertEqual(HomeBackdropMotion.opacity(for: 240), 0)
        XCTAssertEqual(HomeBackdropMotion.opacity(for: 600), 0)
    }
}
