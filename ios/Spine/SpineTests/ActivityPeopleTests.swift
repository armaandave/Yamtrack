import XCTest
@testable import Spine

@MainActor
final class ActivityPeopleTests: XCTestCase {
    func testDecodesTopLevelPersonSnapshot() throws {
        let data = Data(
            """
            {
              "id": 42,
              "type": "list_item_added",
              "created_at": "2026-07-27T12:00:00Z",
              "actor": {
                "id": 1,
                "username": "mobile",
                "display_name": "Mobile",
                "avatar_url": null
              },
              "media": null,
              "person": {
                "source": "tmdb",
                "id": "525",
                "name": "Christopher Nolan",
                "profile_url": "https://example.com/nolan.jpg",
                "known_for_department": "Directing"
              },
              "object": {
                "type": "list",
                "id": 9,
                "name": "Favorite Directors"
              }
            }
            """.utf8
        )

        let activity = try JSONDecoder.api.decode(ActivityItem.self, from: data)

        XCTAssertEqual(activity.person?.ref, PersonRef(source: "tmdb", id: "525"))
        XCTAssertEqual(activity.person?.name, "Christopher Nolan")
        XCTAssertEqual(activity.person?.knownForDepartment, "Directing")
        XCTAssertEqual(ActivityFeedPresentation.actionText(for: activity), "added to a list")
        XCTAssertEqual(ActivityFeedPresentation.listName(for: activity), "Favorite Directors")
        XCTAssertEqual(ActivityFeedPresentation.destinationHint(for: activity), "Opens person details")
    }

    func testDestinationPrecedenceIsDiaryThenPersonThenMediaThenNone() {
        let person = ActivityPersonSnapshot(
            source: "tmdb",
            id: "525",
            name: "Christopher Nolan",
            profileUrl: nil,
            knownForDepartment: nil
        )
        let media = MediaSummary(
            ref: MediaRef(
                itemId: nil,
                source: "tmdb",
                mediaType: "movie",
                mediaId: "13",
                seasonNumber: nil,
                episodeNumber: nil
            ),
            title: "Movie"
        )

        XCTAssertEqual(
            ActivityDestination.resolve(activity(objectType: "diary", media: media, person: person)),
            .diary(7)
        )
        XCTAssertEqual(
            ActivityDestination.resolve(activity(objectType: "list", media: media, person: person)),
            .person(PersonRef(source: "tmdb", id: "525"))
        )
        XCTAssertEqual(
            ActivityDestination.resolve(activity(objectType: "item", media: media)),
            .media(media.ref)
        )
        XCTAssertEqual(
            ActivityDestination.resolve(activity(objectType: "list")),
            .none
        )
    }

    private func activity(
        objectType: String,
        media: MediaSummary? = nil,
        person: ActivityPersonSnapshot? = nil
    ) -> ActivityItem {
        ActivityItem(
            id: 1,
            type: "list_item_added",
            createdAt: nil,
            actor: UserSummary(id: 1, username: "mobile", displayName: "Mobile", avatarUrl: nil),
            media: media,
            person: person,
            object: ActivityObject(
                type: objectType,
                id: 7,
                previous: nil,
                current: nil,
                rating: nil,
                liked: nil,
                name: nil
            )
        )
    }
}
