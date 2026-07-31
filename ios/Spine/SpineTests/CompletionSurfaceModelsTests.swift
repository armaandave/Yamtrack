import XCTest
@testable import Spine

final class CompletionSurfaceModelsTests: XCTestCase {
    func testOnlyListDetailExposesCompletion() throws {
        let summaryJSON = """
        {
          "id": 4,
          "name": "Six Films",
          "slug": "six-films",
          "description": "",
          "visibility": "public",
          "list_type": "media",
          "owner": {
            "id": 1,
            "username": "viewer",
            "display_name": "Viewer",
            "avatar_url": null
          },
          "items_count": 6,
          "like_count": 0,
          "completion": {
            "completed_count": 3,
            "total_count": 6
          }
        }
        """
        let personJSON = """
        {
          "entry_id": 9,
          "id": "819",
          "source": "tmdb",
          "name": "A Person",
          "date_added": "2026-07-31",
          "completion": {
            "completed_count": 12,
            "total_count": 24
          }
        }
        """
        let detailJSON = """
        {
          "id": 4,
          "name": "Six Films",
          "slug": "six-films",
          "description": "",
          "visibility": "public",
          "list_type": "media",
          "owner": {
            "id": 1,
            "username": "viewer",
            "display_name": "Viewer",
            "avatar_url": null
          },
          "items_count": 6,
          "like_count": 0,
          "items": [],
          "people": [],
          "completion": {
            "completed_count": 3,
            "total_count": 6
          }
        }
        """

        let summary = try JSONDecoder.api.decode(
            CustomListSummary.self,
            from: Data(summaryJSON.utf8)
        )
        let detail = try JSONDecoder.api.decode(
            CustomListDetail.self,
            from: Data(detailJSON.utf8)
        )
        let person = try JSONDecoder.api.decode(
            PersonListEntry.self,
            from: Data(personJSON.utf8)
        )

        XCTAssertEqual(summary.name, "Six Films")
        XCTAssertEqual(detail.completion?.countText, "3 of 6")
        XCTAssertEqual(person.name, "A Person")
    }

    func testPersonCompletionDecodesByMediaTypeAndRole() throws {
        let json = """
        {
          "id": "819",
          "source": "tmdb",
          "name": "A Person",
          "credits": {
            "cast": []
          },
          "completion": {
            "completed_count": 5,
            "total_count": 10
          },
          "media_type_completions": {
            "movie": {
              "completed_count": 3,
              "total_count": 6
            }
          },
          "role_completions": {
            "movie": {
              "Actor": {
                "completed_count": 3,
                "total_count": 6
              },
              "Director": {
                "completed_count": 1,
                "total_count": 2
              }
            }
          }
        }
        """

        let detail = try JSONDecoder.api.decode(
            PersonDetail.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(detail.completion?.percentage, 50)
        XCTAssertEqual(detail.mediaTypeCompletions?["movie"]?.countText, "3 of 6")
        XCTAssertEqual(detail.roleCompletions?["movie"]?["Director"]?.percentage, 50)
    }

    func testCompanyCompletionDecodesForOverallAndRoles() throws {
        let json = """
        {
          "id": "42",
          "source": "igdb",
          "media_type": "game",
          "name": "A Studio",
          "websites": [],
          "catalogs": {
            "developed": {
              "count": 6,
              "available": true,
              "completion": {
                "completed_count": 3,
                "total_count": 6
              }
            },
            "published": {
              "count": 4,
              "available": true,
              "completion": {
                "completed_count": 1,
                "total_count": 4
              }
            }
          },
          "completion": {
            "completed_count": 3,
            "total_count": 8
          }
        }
        """

        let detail = try JSONDecoder.api.decode(
            CompanyDetail.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(detail.completion?.countText, "3 of 8")
        XCTAssertEqual(detail.catalogs.developed.completion?.percentage, 50)
        XCTAssertEqual(detail.catalogs.published.completion?.percentage, 25)
    }
}
