import XCTest
@testable import Spine

@MainActor
final class PosterViewerTests: XCTestCase {
    func testViewerItemRequiresAnAbsolutePosterURL() {
        XCTAssertNil(PosterViewerItem(detail: detail(posterURL: nil)))
        XCTAssertNil(PosterViewerItem(detail: detail(posterURL: "   ")))
        XCTAssertNil(PosterViewerItem(detail: detail(posterURL: "poster.jpg")))

        let item = PosterViewerItem(detail: detail(posterURL: "https://example.com/poster.jpg"))
        XCTAssertEqual(item?.url.absoluteString, "https://example.com/poster.jpg")
        XCTAssertEqual(item?.title, "Poster Test")
    }

    func testViewerItemResolvesAspectRatioFromMetadata() throws {
        let explicit = try XCTUnwrap(PosterViewerItem(detail: detail(
            posterURL: "https://example.com/poster.jpg",
            aspectRatio: 0.7,
            width: 700,
            height: 1_000,
            orientation: .landscape
        )))
        XCTAssertEqual(explicit.aspectRatio, 0.7, accuracy: 0.0001)

        let dimensions = try XCTUnwrap(PosterViewerItem(detail: detail(
            posterURL: "https://example.com/poster.jpg",
            width: 600,
            height: 900,
            orientation: .square
        )))
        XCTAssertEqual(dimensions.aspectRatio, 2 / 3, accuracy: 0.0001)

        let landscape = try XCTUnwrap(PosterViewerItem(detail: detail(
            posterURL: "https://example.com/poster.jpg",
            orientation: .landscape
        )))
        XCTAssertEqual(landscape.aspectRatio, 16 / 9, accuracy: 0.0001)
    }

    func testScaleIsClampedToSupportedRange() {
        XCTAssertEqual(PosterViewerLayout.clampedScale(0.25), 1)
        XCTAssertEqual(PosterViewerLayout.clampedScale(2.5), 2.5)
        XCTAssertEqual(PosterViewerLayout.clampedScale(8), 5)
    }

    func testPosterFitsInsideViewportWithoutChangingAspectRatio() {
        let portrait = PosterViewerLayout.fittedSize(
            aspectRatio: 2 / 3,
            in: CGSize(width: 393, height: 852)
        )
        XCTAssertEqual(portrait.width, 393, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 589.5, accuracy: 0.001)

        let landscape = PosterViewerLayout.fittedSize(
            aspectRatio: 16 / 9,
            in: CGSize(width: 393, height: 852)
        )
        XCTAssertEqual(landscape.width, 393, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 221.0625, accuracy: 0.001)
    }

    func testPanOffsetIsBoundedByScaledPosterEdges() {
        let viewport = CGSize(width: 393, height: 852)
        let poster = CGSize(width: 393, height: 589.5)

        XCTAssertEqual(
            PosterViewerLayout.clampedOffset(
                CGSize(width: 100, height: 100),
                scale: 1,
                contentSize: poster,
                viewport: viewport
            ),
            .zero
        )

        let clamped = PosterViewerLayout.clampedOffset(
            CGSize(width: 999, height: -999),
            scale: 2,
            contentSize: poster,
            viewport: viewport
        )
        XCTAssertEqual(clamped.width, 196.5, accuracy: 0.001)
        XCTAssertEqual(clamped.height, -163.5, accuracy: 0.001)
    }

    func testSwipeDownDismissalOnlyRunsAtBaseZoom() {
        XCTAssertTrue(PosterViewerLayout.shouldDismiss(
            translation: CGSize(width: 4, height: 130),
            predictedEndTranslation: CGSize(width: 4, height: 150),
            scale: 1
        ))
        XCTAssertTrue(PosterViewerLayout.shouldDismiss(
            translation: CGSize(width: 4, height: 80),
            predictedEndTranslation: CGSize(width: 4, height: 210),
            scale: 1
        ))
        XCTAssertFalse(PosterViewerLayout.shouldDismiss(
            translation: CGSize(width: 4, height: 180),
            predictedEndTranslation: CGSize(width: 4, height: 240),
            scale: 2
        ))
        XCTAssertFalse(PosterViewerLayout.shouldDismiss(
            translation: CGSize(width: 180, height: 130),
            predictedEndTranslation: CGSize(width: 240, height: 220),
            scale: 1
        ))
    }

    private func detail(
        posterURL: String?,
        aspectRatio: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        orientation: PosterOrientation? = .portrait
    ) -> MediaDetail {
        MediaDetail(
            ref: MediaRef(
                itemId: nil,
                source: "tmdb",
                mediaType: "movie",
                mediaId: "poster-test",
                seasonNumber: nil,
                episodeNumber: nil
            ),
            title: "Poster Test",
            posterUrl: posterURL,
            posterOrientation: orientation,
            posterAspectRatio: aspectRatio,
            posterWidth: width,
            posterHeight: height
        )
    }
}
