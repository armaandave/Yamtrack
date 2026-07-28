import XCTest
@testable import Spine

@MainActor
final class AddToListViewModelTests: XCTestCase {
    func testMediaTargetStillUsesExistingMediaFlow() async throws {
        let repository = AddToListRepositoryFake()
        repository.mediaListResponses = [
            [mediaList(hasItem: false)],
            [mediaList(hasItem: true)],
        ]
        let ref = MediaRef(
            itemId: nil,
            source: "tmdb",
            mediaType: "movie",
            mediaId: "550",
            seasonNumber: nil,
            episodeNumber: nil
        )
        let viewModel = AddToListViewModel(
            target: .media(ref),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertEqual(repository.mediaMembershipRefs.map(\.mediaId), ["550", "550"])
        XCTAssertEqual(repository.addedItems, [.init(listID: 7, ref: ref)])
        guard case let .media(savedRef) = viewModel.target else {
            return XCTFail("Expected media target")
        }
        XCTAssertEqual(savedRef.itemId, 42)
    }

    func testPeopleTargetLoadsAndAddsPerson() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [
            [peopleList(hasPerson: false)],
            [peopleList(hasPerson: true, entryID: 41)],
        ]
        let ref = PersonRef(source: "tmdb", id: "819")
        let viewModel = AddToListViewModel(
            target: .person(ref),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertEqual(repository.peopleMembershipRefs, [ref, ref])
        XCTAssertEqual(repository.addedPeople, [.init(listID: 7, ref: ref)])
        XCTAssertTrue(try XCTUnwrap(viewModel.lists.first).hasPerson == true)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testPeopleAddReplacesTargetWithCanonicalReference() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [
            [peopleList(hasPerson: false)],
            [peopleList(hasPerson: true, entryID: 41)],
        ]
        repository.addPersonResponse = PersonListEntry(
            entryId: 41,
            personId: "canonical-819",
            source: "tmdb",
            name: "Edward Norton",
            profileUrl: nil,
            knownForDepartment: "Acting",
            position: nil,
            dateAdded: "2026-07-28T00:00:00Z"
        )
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "legacy-tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        guard case let .person(savedRef) = viewModel.target else {
            return XCTFail("Expected person target")
        }
        XCTAssertEqual(savedRef, PersonRef(source: "tmdb", id: "canonical-819"))
    }

    func testPeopleTargetRemovesExactMembershipEntry() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [
            [peopleList(hasPerson: true, entryID: 41)],
            [peopleList(hasPerson: false)],
        ]
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertEqual(repository.removedPeople, [.init(listID: 7, entryID: 41)])
        XCTAssertTrue(try XCTUnwrap(viewModel.lists.first).hasPerson != true)
    }

    func testMissingPersonEntryIDRefreshesWithoutGuessingMembershipID() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [
            [peopleList(hasPerson: true)],
            [peopleList(hasPerson: true, entryID: 91)],
        ]
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertTrue(repository.removedPeople.isEmpty)
        XCTAssertEqual(repository.peopleMembershipRefs.count, 2)
        XCTAssertEqual(try XCTUnwrap(viewModel.lists.first).personEntryId, 91)
        XCTAssertEqual(
            viewModel.actionErrorMessage,
            "The list status was refreshed. Try removing this person again."
        )
    }

    func testCreateAndAddCreatesPeopleList() async {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [[peopleList(hasPerson: true, entryID: 41)]]
        let ref = PersonRef(source: "tmdb", id: "819")
        let viewModel = AddToListViewModel(
            target: .person(ref),
            listRepository: repository,
            onUnauthorized: {}
        )

        let created = await viewModel.createAndAdd(name: "  Favorite Actors  ")

        XCTAssertTrue(created)
        XCTAssertEqual(repository.createdRequests.count, 1)
        XCTAssertEqual(repository.createdRequests.first?.name, "Favorite Actors")
        XCTAssertEqual(repository.createdRequests.first?.visibility, "private")
        XCTAssertEqual(repository.createdRequests.first?.isRanked, false)
        XCTAssertEqual(repository.createdRequests.first?.listType, .people)
        XCTAssertEqual(repository.addedPeople, [.init(listID: 7, ref: ref)])
    }

    func testCreateSuccessAndAddFailureRetainsRefreshedEmptyList() async throws {
        let repository = AddToListRepositoryFake()
        repository.addPersonError = AddToListTestError.failed
        repository.peopleListResponses = [[peopleList(hasPerson: false)]]
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: {}
        )

        let created = await viewModel.createAndAdd(name: "Favorite Actors")

        XCTAssertTrue(created)
        XCTAssertEqual(repository.createdRequests.count, 1)
        XCTAssertEqual(viewModel.lists.map(\.id), [7])
        XCTAssertEqual(viewModel.lists.first?.hasPerson, false)
        XCTAssertEqual(
            viewModel.actionErrorMessage,
            "The list was created, but this person could not be added. Add failed"
        )
    }

    func testAddFailurePreservesLoadedLists() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [[peopleList(hasPerson: false)]]
        repository.addPersonError = AddToListTestError.failed
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertEqual(viewModel.lists.count, 1)
        XCTAssertEqual(viewModel.actionErrorMessage, "Add failed")
        XCTAssertNil(viewModel.loadErrorMessage)
    }

    func testCancelledMutationDoesNotSurfaceAnError() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [[peopleList(hasPerson: false)]]
        repository.addPersonError = CancellationError()
        var unauthorizedCount = 0
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: { unauthorizedCount += 1 }
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(unauthorizedCount, 0)
        XCTAssertEqual(viewModel.lists.count, 1)
    }

    func testUnauthorizedLoadCallsSessionHandler() async {
        let repository = AddToListRepositoryFake()
        repository.peopleListsError = APIError.unauthorized
        var unauthorizedCount = 0
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: { unauthorizedCount += 1 }
        )

        await viewModel.load()

        XCTAssertEqual(unauthorizedCount, 1)
        XCTAssertNotNil(viewModel.loadErrorMessage)
    }

    func testUnauthorizedMutationCallsSessionHandler() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [[peopleList(hasPerson: false)]]
        repository.addPersonError = APIError.unauthorized
        var unauthorizedCount = 0
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: { unauthorizedCount += 1 }
        )

        await viewModel.load()
        await viewModel.toggle(try XCTUnwrap(viewModel.lists.first))

        XCTAssertEqual(unauthorizedCount, 1)
        XCTAssertEqual(viewModel.actionErrorMessage, APIError.unauthorized.localizedDescription)
    }

    func testConcurrentMutationAttemptIsIgnored() async throws {
        let repository = AddToListRepositoryFake()
        repository.peopleListResponses = [
            [peopleList(hasPerson: false)],
            [peopleList(hasPerson: true, entryID: 41)],
        ]
        repository.suspendAddPerson = true
        let viewModel = AddToListViewModel(
            target: .person(PersonRef(source: "tmdb", id: "819")),
            listRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()
        let list = try XCTUnwrap(viewModel.lists.first)
        let firstMutation = Task { await viewModel.toggle(list) }
        for _ in 0..<100 where !repository.isAddPersonSuspended {
            await Task.yield()
        }
        XCTAssertTrue(repository.isAddPersonSuspended)

        await viewModel.toggle(list)
        XCTAssertEqual(repository.addedPeople.count, 1)

        repository.resumeAddPerson()
        await firstMutation.value
        XCTAssertEqual(repository.addedPeople.count, 1)
    }

    private func peopleList(hasPerson: Bool, entryID: Int? = nil) -> CustomListSummary {
        CustomListSummary(
            id: 7,
            name: "Favorite Actors",
            slug: "favorite-actors",
            description: "",
            visibility: "private",
            listType: .people,
            hasPerson: hasPerson,
            personEntryId: entryID,
            owner: UserSummary(
                id: 1,
                username: "mobile",
                displayName: "Mobile",
                avatarUrl: nil
            ),
            itemsCount: 0,
            peopleCount: hasPerson ? 1 : 0,
            likeCount: 0
        )
    }

    private func mediaList(hasItem: Bool) -> CustomListSummary {
        CustomListSummary(
            id: 7,
            name: "Favorite Movies",
            slug: "favorite-movies",
            description: "",
            visibility: "private",
            hasItem: hasItem,
            owner: UserSummary(
                id: 1,
                username: "mobile",
                displayName: "Mobile",
                avatarUrl: nil
            ),
            itemsCount: hasItem ? 1 : 0,
            likeCount: 0
        )
    }
}

private enum AddToListTestError: LocalizedError {
    case failed

    var errorDescription: String? { "Add failed" }
}

@MainActor
private final class AddToListRepositoryFake: ListRepository {
    struct AddedItem: Equatable {
        let listID: Int
        let ref: MediaRef
    }

    struct AddedPerson: Equatable {
        let listID: Int
        let ref: PersonRef
    }

    struct RemovedPerson: Equatable {
        let listID: Int
        let entryID: Int
    }

    var mediaListResponses: [[CustomListSummary]] = []
    var peopleListResponses: [[CustomListSummary]] = []
    var mediaMembershipRefs: [MediaRef] = []
    var peopleMembershipRefs: [PersonRef] = []
    var createdRequests: [CustomListWriteRequest] = []
    var addedItems: [AddedItem] = []
    var addedPeople: [AddedPerson] = []
    var removedPeople: [RemovedPerson] = []
    var peopleListsError: Error?
    var addPersonError: Error?
    var addPersonResponse: PersonListEntry?
    var suspendAddPerson = false
    private(set) var isAddPersonSuspended = false
    private var addPersonContinuation: CheckedContinuation<Void, Never>?

    func list(membershipFor ref: MediaRef?) async throws -> [CustomListSummary] {
        if let ref {
            mediaMembershipRefs.append(ref)
        }
        guard !mediaListResponses.isEmpty else { return [] }
        return mediaListResponses.removeFirst()
    }

    func peopleLists(membershipFor ref: PersonRef) async throws -> [CustomListSummary] {
        if let peopleListsError {
            throw peopleListsError
        }
        peopleMembershipRefs.append(ref)
        guard !peopleListResponses.isEmpty else { return [] }
        return peopleListResponses.removeFirst()
    }

    func detail(id: Int) async throws -> CustomListDetail {
        fatalError("Not used")
    }

    func create(_ request: CustomListWriteRequest) async throws -> CustomListSummary {
        createdRequests.append(request)
        return CustomListSummary(
            id: 7,
            name: request.name ?? "",
            slug: "favorite-actors",
            description: "",
            visibility: request.visibility ?? "private",
            listType: request.listType ?? .media,
            owner: UserSummary(
                id: 1,
                username: "mobile",
                displayName: "Mobile",
                avatarUrl: nil
            ),
            itemsCount: 0,
            likeCount: 0
        )
    }

    func update(id: Int, _ request: CustomListWriteRequest) async throws -> CustomListDetail {
        fatalError("Not used")
    }

    func delete(id: Int) async throws {}

    func addItem(listId: Int, ref: MediaRef) async throws -> MediaSummary {
        addedItems.append(.init(listID: listId, ref: ref))
        return MediaSummary(
            ref: MediaRef(
                itemId: 42,
                source: ref.source,
                mediaType: ref.mediaType,
                mediaId: ref.mediaId,
                seasonNumber: ref.seasonNumber,
                episodeNumber: ref.episodeNumber
            ),
            title: "Fight Club"
        )
    }

    func removeItem(listId: Int, itemId: Int) async throws {}

    func reorderItems(listId: Int, itemIds: [Int]) async throws -> CustomListDetail {
        fatalError("Not used")
    }

    func people(listId: Int, page: String?) async throws -> PagedResponse<PersonListEntry> {
        PagedResponse(count: 0, next: nil, previous: nil, results: [])
    }

    func addPerson(listId: Int, ref: PersonRef) async throws -> PersonListEntry {
        if let addPersonError {
            throw addPersonError
        }
        addedPeople.append(.init(listID: listId, ref: ref))
        if suspendAddPerson {
            isAddPersonSuspended = true
            await withCheckedContinuation { continuation in
                addPersonContinuation = continuation
            }
            isAddPersonSuspended = false
        }
        return addPersonResponse ?? PersonListEntry(
            entryId: 41,
            personId: ref.id,
            source: ref.source,
            name: "Edward Norton",
            profileUrl: nil,
            knownForDepartment: "Acting",
            position: nil,
            dateAdded: "2026-07-28T00:00:00Z"
        )
    }

    func resumeAddPerson() {
        suspendAddPerson = false
        addPersonContinuation?.resume()
        addPersonContinuation = nil
    }

    func removePerson(listId: Int, entryId: Int) async throws {
        removedPeople.append(.init(listID: listId, entryID: entryId))
    }

    func reorderPeople(listId: Int, entryIds: [Int]) async throws -> CustomListDetail {
        fatalError("Not used")
    }
}
