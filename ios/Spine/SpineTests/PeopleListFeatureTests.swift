import Foundation
@testable import Spine
import XCTest

@MainActor
final class PeopleListFeatureTests: XCTestCase {
    func testPeopleDetailUsesOnlyPeopleEndpointAndRetriesNextPageWithoutDuplicates() async {
        let first = person(entryId: 1, name: "First")
        let second = person(entryId: 2, name: "Second")
        let repository = PeopleListFeatureRepository(
            people: [first],
            firstPage: PagedResponse(
                count: 2,
                next: "https://example.com/api/lists/77/people/?page=2",
                previous: nil,
                results: [first]
            ),
            nextPageResults: [
                .failure(PeopleListFeatureError.nextPage),
                .success(PagedResponse(count: 2, next: nil, previous: nil, results: [first, second]))
            ]
        )
        let filters = PeopleListFeatureFilterRepository()
        let viewModel = ProfileListDetailViewModel(
            listId: 77,
            listRepository: repository,
            filterOptionsRepository: filters,
            onUnauthorized: {}
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.displayedPeople.map(\.entryId), [1])
        XCTAssertEqual(repository.detailCalls, 1)
        XCTAssertEqual(repository.peoplePages, [nil])
        XCTAssertEqual(repository.itemCalls, 0)
        XCTAssertEqual(filters.calls, 0)

        await viewModel.loadNextPeoplePageIfNeeded(currentPerson: first)

        XCTAssertNotNil(viewModel.nextPageErrorMessage)
        XCTAssertEqual(viewModel.displayedPeople.map(\.entryId), [1])

        await viewModel.retryNextPage()

        XCTAssertNil(viewModel.nextPageErrorMessage)
        XCTAssertEqual(viewModel.displayedPeople.map(\.entryId), [1, 2])
        XCTAssertEqual(repository.peoplePages, [nil, "2", "2"])
        XCTAssertEqual(repository.itemCalls, 0)
        XCTAssertEqual(filters.calls, 0)
    }

    func testEmptyPeopleListCreationSendsTypeAndNeedsOnlyAName() async {
        let repository = PeopleListFeatureRepository(nextPageResults: [])
        let viewModel = ListComposerViewModel(
            mode: .create(.people),
            listRepository: repository,
            onUnauthorized: {}
        )

        viewModel.draft.name = "Authors"
        XCTAssertTrue(viewModel.canSave)

        let listID = await viewModel.save()

        XCTAssertEqual(listID, 77)
        XCTAssertEqual(repository.createRequests.count, 1)
        XCTAssertEqual(repository.createRequests.first?.listType, .people)
        XCTAssertEqual(repository.reorderedPeople, [[]])
        XCTAssertEqual(repository.itemCalls, 0)
    }

    func testPeopleEditRetriesRemovalThenSendsCompleteOrderAndNeverChangesType() async {
        let first = person(entryId: 1, name: "First", position: 1)
        let second = person(entryId: 2, name: "Second", position: 2)
        let third = person(entryId: 3, name: "Third", position: 3)
        let repository = PeopleListFeatureRepository(
            people: [first, second, third],
            nextPageResults: [],
            removalFailures: 1
        )
        let viewModel = ListComposerViewModel(
            mode: .edit(peopleList(people: [first, second, third])),
            listRepository: repository,
            onUnauthorized: {}
        )
        viewModel.removePerson(entryId: second.entryId)
        viewModel.movePerson(from: 1, to: 0)

        let firstSave = await viewModel.save()
        XCTAssertNil(firstSave)
        XCTAssertEqual(viewModel.phase, .failed)
        XCTAssertEqual(repository.removedPeople, [2])
        XCTAssertEqual(repository.reorderedPeople, [])

        let listID = await viewModel.save()

        XCTAssertEqual(listID, 77)
        XCTAssertEqual(repository.updateRequests.count, 2)
        XCTAssertTrue(repository.updateRequests.allSatisfy { $0.listType == nil })
        XCTAssertEqual(repository.removedPeople, [2, 2])
        XCTAssertEqual(repository.reorderedPeople, [[3, 1]])
        XCTAssertEqual(repository.serverPeople.map(\.entryId), [3, 1])
        XCTAssertGreaterThanOrEqual(repository.peoplePages.count, 2)
        XCTAssertEqual(repository.itemCalls, 0)
    }

    private func person(
        entryId: Int,
        name: String,
        source: String = "tmdb",
        position: Int? = nil
    ) -> PersonListEntry {
        PersonListEntry(
            entryId: entryId,
            personId: String(entryId * 10),
            source: source,
            name: name,
            profileUrl: nil,
            knownForDepartment: "Acting",
            position: position,
            dateAdded: "2026-07-27T12:00:00Z"
        )
    }

    private func peopleList(people: [PersonListEntry]) -> CustomListDetail {
        CustomListDetail(
            id: 77,
            name: "People",
            slug: "people",
            description: "",
            visibility: "private",
            isRanked: true,
            listType: .people,
            owner: Self.owner,
            itemsCount: 0,
            peopleCount: people.count,
            entriesCount: people.count,
            likeCount: 0,
            items: [],
            people: people
        )
    }

    fileprivate static let owner = UserSummary(
        id: 1,
        username: "mobile",
        displayName: "Mobile",
        avatarUrl: nil
    )
}

private enum PeopleListFeatureError: LocalizedError {
    case nextPage
    case removal

    var errorDescription: String? {
        switch self {
        case .nextPage: "Next page failed"
        case .removal: "Removal failed"
        }
    }
}

@MainActor
private final class PeopleListFeatureFilterRepository: FilterOptionsRepository {
    var calls = 0

    func options(scope: MediaFilterScope, filter: MediaFilterState) async throws -> MediaFilterOptionsResponse {
        calls += 1
        return .empty
    }
}

@MainActor
private final class PeopleListFeatureRepository: ListRepository {
    var detailCalls = 0
    var peoplePages: [String?] = []
    var itemCalls = 0
    var createRequests: [CustomListWriteRequest] = []
    var updateRequests: [CustomListWriteRequest] = []
    var removedPeople: [Int] = []
    var reorderedPeople: [[Int]] = []
    var serverPeople: [PersonListEntry]

    private let firstPage: PagedResponse<PersonListEntry>?
    private var nextPageResults: [Result<PagedResponse<PersonListEntry>, Error>]
    private var removalFailures: Int

    init(
        people: [PersonListEntry] = [],
        firstPage: PagedResponse<PersonListEntry>? = nil,
        nextPageResults: [Result<PagedResponse<PersonListEntry>, Error>],
        removalFailures: Int = 0
    ) {
        serverPeople = people
        self.firstPage = firstPage
        self.nextPageResults = nextPageResults
        self.removalFailures = removalFailures
    }

    func list(membershipFor ref: MediaRef?) async throws -> [CustomListSummary] { [] }
    func peopleLists(membershipFor ref: PersonRef) async throws -> [CustomListSummary] { [] }

    func detail(id: Int) async throws -> CustomListDetail {
        detailCalls += 1
        return detail()
    }

    func create(_ request: CustomListWriteRequest) async throws -> CustomListSummary {
        createRequests.append(request)
        return CustomListSummary(
            id: 77,
            name: request.name ?? "",
            slug: "people",
            description: request.description ?? "",
            visibility: request.visibility ?? "private",
            isRanked: request.isRanked ?? false,
            listType: request.listType ?? .media,
            owner: PeopleListFeatureTests.owner,
            itemsCount: 0,
            peopleCount: serverPeople.count,
            entriesCount: serverPeople.count,
            likeCount: 0
        )
    }

    func update(id: Int, _ request: CustomListWriteRequest) async throws -> CustomListDetail {
        updateRequests.append(request)
        return detail()
    }

    func delete(id: Int) async throws {}

    func addItem(listId: Int, ref: MediaRef) async throws -> MediaSummary {
        fatalError("People lists must not add media")
    }

    func items(
        listId: Int,
        page: String?,
        filter: MediaFilterState
    ) async throws -> PagedResponse<MediaSummary> {
        itemCalls += 1
        return PagedResponse(count: 0, next: nil, previous: nil, results: [])
    }

    func removeItem(listId: Int, itemId: Int) async throws {
        fatalError("People lists must not remove media")
    }

    func reorderItems(listId: Int, itemIds: [Int]) async throws -> CustomListDetail {
        fatalError("People lists must not reorder media")
    }

    func people(listId: Int, page: String?) async throws -> PagedResponse<PersonListEntry> {
        peoplePages.append(page)
        if page == nil, let firstPage {
            return firstPage
        }
        if page != nil, !nextPageResults.isEmpty {
            return try nextPageResults.removeFirst().get()
        }
        return PagedResponse(
            count: serverPeople.count,
            next: nil,
            previous: nil,
            results: serverPeople
        )
    }

    func addPerson(listId: Int, ref: PersonRef) async throws -> PersonListEntry {
        fatalError("Composer has no people picker")
    }

    func removePerson(listId: Int, entryId: Int) async throws {
        removedPeople.append(entryId)
        if removalFailures > 0 {
            removalFailures -= 1
            throw PeopleListFeatureError.removal
        }
        serverPeople.removeAll { $0.entryId == entryId }
    }

    func reorderPeople(listId: Int, entryIds: [Int]) async throws -> CustomListDetail {
        reorderedPeople.append(entryIds)
        let byID = Dictionary(uniqueKeysWithValues: serverPeople.map { ($0.entryId, $0) })
        serverPeople = entryIds.compactMap { byID[$0] }
        return detail()
    }

    private func detail() -> CustomListDetail {
        CustomListDetail(
            id: 77,
            name: "People",
            slug: "people",
            description: "",
            visibility: "private",
            isRanked: true,
            listType: .people,
            owner: PeopleListFeatureTests.owner,
            itemsCount: 0,
            peopleCount: serverPeople.count,
            entriesCount: serverPeople.count,
            likeCount: 0,
            items: [],
            people: serverPeople
        )
    }
}
