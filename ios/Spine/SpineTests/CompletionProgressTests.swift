import XCTest
@testable import Spine

@MainActor
final class CompletionProgressTests: XCTestCase {
    func testDisplayClampsCountsAndRoundsPercentage() {
        let partial = CompletionProgress(completedCount: 2, totalCount: 3)
        XCTAssertEqual(partial.normalizedCompletedCount, 2)
        XCTAssertEqual(partial.percentage, 67)
        XCTAssertEqual(partial.percentageText, "67%")
        XCTAssertEqual(partial.countText, "2 of 3")
        XCTAssertTrue(partial.isVisible)

        let excessive = CompletionProgress(completedCount: 12, totalCount: 6)
        XCTAssertEqual(excessive.normalizedCompletedCount, 6)
        XCTAssertEqual(excessive.percentage, 100)

        let empty = CompletionProgress(completedCount: -2, totalCount: 0)
        XCTAssertEqual(empty.normalizedCompletedCount, 0)
        XCTAssertEqual(empty.percentage, 0)
        XCTAssertFalse(empty.isVisible)
    }

    func testPagedResponseDecodesCompletion() throws {
        let json = """
        {
          "count": 6,
          "next": null,
          "previous": null,
          "results": [],
          "completion": {
            "completed_count": 3,
            "total_count": 6
          }
        }
        """

        let response = try JSONDecoder.api.decode(
            PagedResponse<MediaSummary>.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.completion, CompletionProgress(completedCount: 3, totalCount: 6))
    }

    func testMediaDetailDecodesFiniteGroupCompletion() throws {
        let json = """
        {
          "ref": {
            "source": "tmdb",
            "media_type": "tv",
            "media_id": "1399"
          },
          "title": "A Show",
          "completion": {
            "completed_count": 5,
            "total_count": 10
          },
          "seasons": [
            {
              "season_number": 1,
              "title": "Season 1",
              "episode_count": 10,
              "image_url": null,
              "release_date": null,
              "completion": {
                "completed_count": 5,
                "total_count": 10
              }
            }
          ],
          "related_sections": [
            {
              "id": "collection",
              "title": "Collection",
              "items": [],
              "completion": {
                "completed_count": 1,
                "total_count": 3
              }
            }
          ]
        }
        """

        let detail = try JSONDecoder.api.decode(MediaDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.completion?.percentageText, "50%")
        XCTAssertEqual(detail.seasons?.first?.completion?.countText, "5 of 10")
        XCTAssertEqual(detail.relatedSections?.first?.completion?.percentage, 33)
    }

    func testSeriesAndStatsProgressDecode() throws {
        let seriesJSON = """
        {
          "id": "10",
          "source": "tmdb",
          "media_type": "movie",
          "name": "A Collection",
          "item_count": 4,
          "items": [],
          "completion": {
            "completed_count": 3,
            "total_count": 4
          }
        }
        """
        let series = try JSONDecoder.api.decode(SeriesDetail.self, from: Data(seriesJSON.utf8))
        XCTAssertEqual(series.completion?.percentage, 75)

        let statsJSON = """
        {
          "overview": {
            "completion": {
              "completed_count": 8,
              "total_count": 10
            }
          },
          "list_progress": [
            {
              "id": 7,
              "name": "Essentials",
              "media_type": null,
              "poster_urls": [],
              "completion": {
                "completed_count": 4,
                "total_count": 5
              }
            }
          ],
          "series_progress": [
            {
              "id": "10",
              "source": "tmdb",
              "media_type": "movie",
              "name": "A Collection",
              "item_count": 4,
              "poster_urls": [],
              "completion": {
                "completed_count": 3,
                "total_count": 4
              }
            }
          ]
        }
        """
        let stats = try JSONDecoder.api.decode(StatsSummary.self, from: Data(statsJSON.utf8))

        XCTAssertEqual(stats.overview.completion?.percentage, 80)
        XCTAssertEqual(stats.listProgress.first?.completion.countText, "4 of 5")
        XCTAssertEqual(stats.seriesProgress.first?.completion?.percentageText, "75%")
        XCTAssertFalse(stats.isEmpty)
    }
}
