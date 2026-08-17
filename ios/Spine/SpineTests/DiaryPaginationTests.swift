import XCTest
@testable import Spine

@MainActor
final class DiaryPaginationTests: XCTestCase {
    func testDiaryMediaPrefersCustomPoster() throws {
        let entry = try diaryEntry(
            id: 1,
            title: "Custom Art",
            customPosterURL: "https://example.com/custom.jpg"
        )

        XCTAssertEqual(entry.media.displayPosterURL, "https://example.com/custom.jpg")
    }

    func testAutomaticLoadOnlyRunsOnceWhenDiaryReappears() async throws {
        let entry = try diaryEntry(id: 1, title: "First")
        let repository = ScriptedDiaryPaginationRepository(results: [
            .success(PagedResponse(count: 1, next: nil, previous: nil, results: [entry])),
        ])
        let viewModel = DiaryViewModel(diaryRepository: repository, onUnauthorized: {})

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        XCTAssertEqual(repository.requestedPages.count, 1)
        XCTAssertEqual(viewModel.entries.map(\.id), [1])
    }

    func testCancelledNextPageDoesNotBecomeAnErrorAndCanRetry() async throws {
        let first = try diaryEntry(id: 1, title: "First")
        let second = try diaryEntry(id: 2, title: "Second")
        let repository = ScriptedDiaryPaginationRepository(results: [
            .success(PagedResponse(
                count: 2,
                next: "https://example.com/api/diary/?page=2",
                previous: nil,
                results: [first]
            )),
            .failure(CancellationError()),
            .success(PagedResponse(count: 2, next: nil, previous: nil, results: [second])),
        ])
        let viewModel = DiaryViewModel(diaryRepository: repository, onUnauthorized: {})

        await viewModel.load()
        await viewModel.loadNextPage()

        XCTAssertNil(viewModel.nextPageErrorMessage)
        XCTAssertFalse(viewModel.isLoadingNextPage)
        XCTAssertEqual(viewModel.entries.map(\.id), [1])

        await viewModel.loadNextPage()

        XCTAssertNil(viewModel.nextPageErrorMessage)
        XCTAssertEqual(viewModel.entries.map(\.id), [1, 2])
        XCTAssertEqual(repository.requestedPages, [nil, "2", "2"])
    }

    func testInitialLoadDoesNotPreloadRemainingPages() async throws {
        let june = try diaryEntry(id: 1, title: "June", consumedAt: "2026-06-20T12:00:00Z")
        let repository = ScriptedDiaryPaginationRepository(results: [
            .success(PagedResponse(count: 3, next: "https://example.com/api/diary/?page=2", previous: nil, results: [june])),
        ])
        let viewModel = DiaryViewModel(diaryRepository: repository, onUnauthorized: {})

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.entries.map(\.id), [1])
        XCTAssertEqual(repository.requestedPages, [nil])
        XCTAssertTrue(viewModel.hasMorePages)
        XCTAssertFalse(viewModel.hasLoadedAllEntries)
    }

    func testCollapseLoadsRemainingPagesWithoutReplacingTheDiary() async throws {
        let june = try diaryEntry(id: 1, title: "June")
        let may = try diaryEntry(id: 2, title: "May", consumedAt: "2026-05-20T12:00:00Z")
        let april = try diaryEntry(id: 3, title: "April", consumedAt: "2026-04-20T12:00:00Z")
        let repository = ScriptedDiaryPaginationRepository(results: [
            .success(PagedResponse(
                count: 3,
                next: "https://example.com/api/diary/?page=2",
                previous: nil,
                results: [june]
            )),
            .success(PagedResponse(
                count: 3,
                next: "https://example.com/api/diary/?page=3",
                previous: nil,
                results: [may]
            )),
            .success(PagedResponse(count: 3, next: nil, previous: nil, results: [april])),
        ])
        let viewModel = DiaryViewModel(diaryRepository: repository, onUnauthorized: {})

        await viewModel.loadIfNeeded()
        await viewModel.loadRemainingPages()

        XCTAssertEqual(viewModel.entries.map(\.id), [1, 2, 3])
        XCTAssertEqual(repository.requestedPages, [nil, "2", "3"])
        XCTAssertFalse(viewModel.hasMorePages)
        XCTAssertTrue(viewModel.hasLoadedAllEntries)
    }

    func testMonthSectionsKeepStableIDsAndCombineMatchingMonths() throws {
        let july = try diaryEntry(id: 1, title: "July", consumedAt: "2026-07-20T12:00:00Z")
        let juneOne = try diaryEntry(id: 2, title: "June One", consumedAt: "2026-06-20T12:00:00Z")
        let may = try diaryEntry(id: 3, title: "May", consumedAt: "2026-05-20T12:00:00Z")
        let juneTwo = try diaryEntry(id: 4, title: "June Two", consumedAt: "2026-06-10T12:00:00Z")
        let april = try diaryEntry(id: 5, title: "April", consumedAt: "2026-04-20T12:00:00Z")
        let original = DiaryMonthSection.sections(from: [juneOne, may])

        let updated = DiaryMonthSection.sections(from: [july, juneOne, may, juneTwo, april])

        XCTAssertEqual(updated.map(\.id), ["2026-07", original[0].id, original[1].id, "2026-04"])
        XCTAssertEqual(updated[1].entries.map(\.id), [2, 4])
    }

    private func diaryEntry(
        id: Int,
        title: String,
        customPosterURL: String? = nil,
        consumedAt: String = "2026-06-20T12:00:00Z"
    ) throws -> DiaryEntry {
        let encodedCustomPosterURL = customPosterURL.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder.api.decode(
            DiaryEntry.self,
            from: """
            {
              "id": \(id),
              "user": { "id": 1, "username": "mobile", "display_name": "Mobile", "avatar_url": null },
              "media": {
                "ref": { "item_id": \(100 + id), "source": "tmdb", "media_type": "movie", "media_id": "\(id)", "season_number": null, "episode_number": null },
                "title": "\(title)",
                "image_url": "https://example.com/original.jpg",
                "poster_url": "https://example.com/original.jpg",
                "custom_poster_url": \(encodedCustomPosterURL)
              },
              "consumed_at": "\(consumedAt)",
              "rating": null,
              "review_title": "",
              "review": "",
              "contains_spoilers": false,
              "liked": false,
              "is_rewatch": false,
              "tags": [],
              "visibility": "public",
              "like_count": 0,
              "viewer_has_liked": false,
              "created_at": "\(consumedAt)",
              "updated_at": "\(consumedAt)"
            }
            """.data(using: .utf8)!
        )
    }
}

@MainActor
private final class ScriptedDiaryPaginationRepository: DiaryRepository {
    private var results: [Result<PagedResponse<DiaryEntry>, Error>]
    private(set) var requestedPages: [String?] = []

    init(results: [Result<PagedResponse<DiaryEntry>, Error>]) {
        self.results = results
    }

    func page(filter: MediaFilterState, page: String?) async throws -> PagedResponse<DiaryEntry> {
        requestedPages.append(page)
        return try results.removeFirst().get()
    }

    func list(tag: String?) async throws -> [DiaryEntry] { fatalError("Not used") }
    func detail(id: Int) async throws -> DiaryEntry { fatalError("Not used") }
    func create(_ request: DiaryEntryWriteRequest) async throws -> DiaryEntry { fatalError("Not used") }
    func setLike(entryId: Int, liked: Bool) async throws -> LikeState { fatalError("Not used") }
    func tags(query: String) async throws -> [DiaryTagSuggestion] { fatalError("Not used") }
}
