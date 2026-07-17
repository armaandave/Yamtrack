import SwiftUI
import XCTest
@testable import Spine

final class HallOfFameCrownLayoutTests: XCTestCase {
    func testCrownLayoutReturnsEmptyForZeroCount() {
        let placements = HallOfFameCrownLayout.placements(
            count: 0,
            cardSize: CGSize(width: 50, height: 75),
            avatarDiameter: 128
        )

        XCTAssertEqual(placements, [])
    }

    func testCrownLayoutSymmetricForTwoCards() {
        let placements = HallOfFameCrownLayout.placements(
            count: 2,
            cardSize: CGSize(width: 60, height: 90),
            avatarDiameter: 128
        )

        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements[0].x, -placements[1].x, accuracy: 0.001)
        XCTAssertEqual(placements[0].rotation.degrees, -placements[1].rotation.degrees, accuracy: 0.001)
    }

    func testCrownLayoutCenterCardUprightForThree() {
        let placements = HallOfFameCrownLayout.placements(
            count: 3,
            cardSize: CGSize(width: 58, height: 87),
            avatarDiameter: 128
        )

        XCTAssertEqual(placements.count, 3)
        XCTAssertEqual(placements[1].x, 0, accuracy: 0.001)
        XCTAssertEqual(placements[1].rotation.degrees, 0, accuracy: 0.001)
    }

    func testCrownLayoutShowsEightSlots() {
        let placements = HallOfFameCrownLayout.placements(
            count: 8,
            cardSize: CGSize(width: 50, height: 75),
            avatarDiameter: 128
        )

        XCTAssertEqual(placements.count, 8)
    }

    func testFavoriteSlotsSortOrderPreserved() {
        let hof: [String: MediaSummary?] = [
            "comic": nil,
            "book": nil,
            "movie": nil,
            "anime": nil,
            "game": nil,
            "tv": nil,
            "manga": nil,
            "music": nil,
        ]

        XCTAssertEqual(
            ProfileFavorites.slots(from: hof).map(\.id),
            ["movie", "tv", "anime", "manga", "game", "book", "comic", "music"]
        )
    }

    func testFavoriteSlotsIncludeDefaultEmptyChoicesWhenAPIOnlySendsFilledItems() {
        let movie = media(index: 1, mediaType: "movie")
        let book = media(index: 2, mediaType: "book")
        let slots = ProfileFavorites.slots(from: [
            "movie": movie,
            "book": book,
        ])

        XCTAssertEqual(slots.map(\.id), ["movie", "tv", "anime", "manga", "game", "book", "comic", "music"])
        XCTAssertEqual(slots.compactMap(\.item).map(\.id), [movie.id, book.id])
    }

    func testFavoriteSlotsPreserveEmptyAndFilledState() {
        let movie = media(index: 1, mediaType: "movie")
        let slots = ProfileFavorites.slots(from: [
            "movie": movie,
            "tv": nil,
        ])

        XCTAssertEqual(slots.count, 8)
        XCTAssertEqual(slots[0].id, "movie")
        XCTAssertEqual(slots[0].item?.id, movie.id)
        XCTAssertEqual(slots[1].id, "tv")
        XCTAssertNil(slots[1].item)
    }

    func testCrownLayoutUsesGeometricArcForEightSlots() {
        let placements = HallOfFameCrownLayout.placements(
            count: 8,
            cardSize: CGSize(width: 50, height: 75),
            avatarDiameter: 128
        )

        XCTAssertEqual(placements[3].x, -placements[4].x, accuracy: 0.001)
        XCTAssertEqual(placements[3].rotation.degrees, -placements[4].rotation.degrees, accuracy: 0.001)
        XCTAssertEqual(placements[0].x, -placements[7].x, accuracy: 0.001)
        XCTAssertEqual(placements[0].y, placements[7].y, accuracy: 0.001)
        XCTAssertEqual(placements[0].rotation.degrees, -placements[7].rotation.degrees, accuracy: 0.001)
    }

    func testCrownLayoutRaisesCenterCardAboveAvatar() {
        let placements = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128
        )

        XCTAssertLessThan(placements[3].y, -96)
    }

    func testBelowAvatarCrownMirrorsExpandedArcVertically() {
        let above = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128
        )
        let below = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128,
            position: .belowAvatar
        )

        XCTAssertEqual(below.count, above.count)
        for index in below.indices {
            XCTAssertEqual(below[index].x, above[index].x, accuracy: 0.001)
            XCTAssertEqual(below[index].y, -above[index].y, accuracy: 0.001)
            XCTAssertEqual(below[index].rotation.degrees, -above[index].rotation.degrees, accuracy: 0.001)
            XCTAssertEqual(below[index].scale, above[index].scale, accuracy: 0.001)
        }
    }

    func testCollapsedCrownProgressZeroMatchesExpandedLayout() {
        let expanded = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128
        )
        let collapsedAtZero = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128,
            collapseProgress: 0
        )

        XCTAssertEqual(collapsedAtZero, expanded)
    }

    func testCollapsedCrownProgressOneConvergesAtAvatarCenter() {
        let placements = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128,
            collapseProgress: 1
        )

        XCTAssertEqual(placements.count, 7)
        for placement in placements {
            XCTAssertEqual(placement.x, 0, accuracy: 0.001)
            XCTAssertEqual(placement.y, 0, accuracy: 0.001)
            XCTAssertEqual(placement.rotation.degrees, 0, accuracy: 0.001)
            XCTAssertEqual(placement.scale, 0.28, accuracy: 0.001)
            XCTAssertEqual(placement.zIndex, 0, accuracy: 0.001)
        }
    }

    func testBelowAvatarCrownProgressOneConvergesAtAvatarCenter() {
        let placements = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128,
            collapseProgress: 1,
            position: .belowAvatar
        )

        for placement in placements {
            XCTAssertEqual(placement.x, 0, accuracy: 0.001)
            XCTAssertEqual(placement.y, 0, accuracy: 0.001)
            XCTAssertEqual(placement.rotation.degrees, 0, accuracy: 0.001)
        }
    }

    func testCollapsedCrownMidpointClosesArcInward() {
        let expanded = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128
        )
        let midpoint = HallOfFameCrownLayout.placements(
            count: 7,
            cardSize: CGSize(width: 54, height: 81),
            avatarDiameter: 128,
            collapseProgress: 0.5
        )

        XCTAssertEqual(midpoint[0].x, expanded[0].x * 0.25, accuracy: 0.001)
        XCTAssertEqual(midpoint[0].y, expanded[0].y * 0.75, accuracy: 0.001)
        XCTAssertEqual(midpoint[0].rotation.degrees, expanded[0].rotation.degrees * 0.5, accuracy: 0.001)
        XCTAssertEqual(midpoint[0].scale, (expanded[0].scale + 0.28) / 2, accuracy: 0.001)
    }

    func testProfileHeroCollapseProgressClampsAtRestAndRefreshPull() {
        XCTAssertEqual(ProfileHeroCollapse.progress(for: 0), 0)
        XCTAssertEqual(ProfileHeroCollapse.progress(for: -24), 0)
    }

    func testProfileHeroCollapseProgressMapsFirstHundredPoints() {
        XCTAssertEqual(ProfileHeroCollapse.progress(for: 50), 0.5)
        XCTAssertEqual(ProfileHeroCollapse.progress(for: 100), 1)
        XCTAssertEqual(ProfileHeroCollapse.progress(for: 140), 1)
    }

    private func media(index: Int, mediaType: String) -> MediaSummary {
        MediaSummary(
            ref: MediaRef(
                itemId: index,
                source: "test",
                mediaType: mediaType,
                mediaId: "\(index)",
                seasonNumber: nil,
                episodeNumber: nil
            ),
            title: "Favorite \(index)",
            posterOrientation: .portrait
        )
    }
}
