import CoreGraphics
import XCTest
@testable import Spine

final class TitleLogoLayoutTests: XCTestCase {
    func testWideLogoUsesItsFittedHeight() {
        let size = titleLogoSize(
            availableWidth: 160,
            maxLogoHeight: 44,
            aspectRatio: 8
        )

        XCTAssertEqual(size.width, 160, accuracy: 0.001)
        XCTAssertEqual(size.height, 20, accuracy: 0.001)
    }

    func testTallLogoRemainsCapped() {
        let size = titleLogoSize(
            availableWidth: 160,
            maxLogoHeight: 44,
            aspectRatio: 1
        )

        XCTAssertEqual(size.width, 63.8, accuracy: 0.001)
        XCTAssertEqual(size.height, 63.8, accuracy: 0.001)
    }

    func testMissingAspectRatioKeepsFallbackHeight() {
        let size = titleLogoSize(
            availableWidth: 160,
            maxLogoHeight: 44,
            aspectRatio: nil
        )

        XCTAssertEqual(size.width, 160, accuracy: 0.001)
        XCTAssertEqual(size.height, 44, accuracy: 0.001)
    }
}
