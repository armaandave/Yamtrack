import Foundation
@testable import Spine
import XCTest

@MainActor
final class PeopleListPickerTests: XCTestCase {
    func testPeopleSearchRequestAndResponseContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PeopleSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = KeychainTokenStore.shared
        tokenStore.accessToken = "people-search-access"
        defer {
            tokenStore.clear()
            PeopleSearchURLProtocol.handler = nil
        }

        PeopleSearchURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url?.path.hasSuffix("/people/search") == true)
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems,
                [URLQueryItem(name: "q", value: "Rebecca Ferguson")]
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer people-search-access"
            )
            return PeopleSearchURLProtocol.response(
                request,
                status: 200,
                body: """
                {
                  "count": 1,
                  "next": null,
                  "previous": null,
                  "results": [{
                    "ref": {"source": "tmdb", "id": "933238"},
                    "name": "Rebecca Ferguson",
                    "profile_url": null,
                    "known_for_department": "Acting"
                  }],
                  "unavailable_sources": ["hardcover"]
                }
                """
            )
        }

        let repository = APIPeopleRepository(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!,
                tokenProvider: tokenStore,
                session: session
            )
        )
        let response = try await repository.search(query: "Rebecca Ferguson")

        XCTAssertEqual(response.results.first?.ref, PersonRef(source: "tmdb", id: "933238"))
        XCTAssertEqual(response.results.first?.name, "Rebecca Ferguson")
        XCTAssertNil(response.results.first?.profileUrl)
        XCTAssertEqual(response.results.first?.knownForDepartment, "Acting")
        XCTAssertEqual(response.unavailableSources, ["hardcover"])
    }

    func testSearchDeduplicatesProviderRefsAndReportsPartialSources() async {
        let duplicate = searchPerson(source: "tmdb", id: "1", name: "Same Person")
        let otherSource = searchPerson(source: "hardcover", id: "1", name: "Same Person")
        let repository = PickerPeopleRepository { query in
            XCTAssertEqual(query, "Same Person")
            return PersonSearchResponse(
                count: 3,
                results: [duplicate, duplicate, otherSource],
                unavailableSources: ["musicbrainz"]
            )
        }
        let viewModel = PeopleSearchViewModel(
            peopleRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.search("  Same Person  ")

        XCTAssertEqual(viewModel.results.map(\.ref), [duplicate.ref, otherSource.ref])
        XCTAssertEqual(viewModel.unavailableSources, ["musicbrainz"])
        XCTAssertEqual(otherSource.ref.sourceDisplayName, "Hardcover")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testNewerSearchWinsWhenAnOlderSearchFinishesLater() async {
        let slow = searchPerson(source: "tmdb", id: "1", name: "Slow")
        let fast = searchPerson(source: "tmdb", id: "2", name: "Fast")
        let repository = PickerPeopleRepository { query in
            if query == "slow" {
                try await Task.sleep(for: .milliseconds(80))
                return PersonSearchResponse(count: 1, results: [slow])
            }
            return PersonSearchResponse(count: 1, results: [fast])
        }
        let viewModel = PeopleSearchViewModel(
            peopleRepository: repository,
            onUnauthorized: {}
        )

        let slowSearch = Task { await viewModel.search("slow") }
        while repository.queries.isEmpty {
            await Task.yield()
        }
        await viewModel.search("fast")
        await slowSearch.value

        XCTAssertEqual(viewModel.results.map(\.name), ["Fast"])
        XCTAssertFalse(viewModel.isLoading)
    }

    func testSearchTreatsCancellationAsNormalAndHandlesUnauthorized() async {
        let cancelled = PeopleSearchViewModel(
            peopleRepository: PickerPeopleRepository { _ in throw CancellationError() },
            onUnauthorized: { XCTFail("Cancellation must not log out") }
        )

        await cancelled.search("cancel")

        XCTAssertNil(cancelled.errorMessage)
        XCTAssertFalse(cancelled.isLoading)

        var unauthorizedCount = 0
        let unauthorized = PeopleSearchViewModel(
            peopleRepository: PickerPeopleRepository { _ in throw APIError.unauthorized },
            onUnauthorized: { unauthorizedCount += 1 }
        )

        await unauthorized.search("private")

        XCTAssertEqual(unauthorizedCount, 1)
        XCTAssertNotNil(unauthorized.errorMessage)
        XCTAssertFalse(unauthorized.isLoading)
    }

    func testEditStagesAddRemoveAndOrderWithCanonicalPersonRef() async {
        let first = listPerson(entryId: 1, source: "tmdb", personId: "1", name: "First")
        let second = listPerson(entryId: 2, source: "tmdb", personId: "2", name: "Second")
        let selectedRef = PersonRef(source: "legacy-tmdb", id: "3")
        let canonicalRef = PersonRef(source: "tmdb", id: "3")
        let repository = PickerListRepository(
            serverPeople: [first, second],
            canonicalRefs: [selectedRef: canonicalRef],
            failuresByRef: [:]
        )
        let viewModel = ListComposerViewModel(
            mode: .edit(peopleList([first, second])),
            listRepository: repository,
            onUnauthorized: {}
        )

        viewModel.removePerson(entryId: first.entryId)
        viewModel.toggleSelection(
            searchPerson(source: selectedRef.source, id: selectedRef.id, name: "Third")
        )
        viewModel.movePerson(from: 1, to: 0)

        XCTAssertTrue(viewModel.draft.people.contains { $0.entryId < 0 })

        let savedID = await viewModel.save()

        XCTAssertEqual(savedID, 77)
        XCTAssertEqual(repository.addedRefs, [selectedRef])
        XCTAssertEqual(repository.removedEntryIDs, [1])
        XCTAssertEqual(repository.reorderedEntryIDs.count, 1)
        XCTAssertTrue(repository.reorderedEntryIDs[0].allSatisfy { $0 > 0 })
        XCTAssertEqual(viewModel.draft.people.map(\.ref), [canonicalRef, second.ref])
        XCTAssertTrue(viewModel.draft.people.allSatisfy { $0.entryId > 0 })
    }

    func testCreateRetriesOnlyFailedPersonAndNeverSendsTemporaryIDs() async {
        let first = searchPerson(source: "tmdb", id: "1", name: "First")
        let second = searchPerson(source: "hardcover", id: "2", name: "Second")
        let repository = PickerListRepository(
            canonicalRefs: [:],
            failuresByRef: [second.ref: 1]
        )
        let viewModel = ListComposerViewModel(
            mode: .create(.people),
            listRepository: repository,
            onUnauthorized: {}
        )
        viewModel.draft.name = "People"
        viewModel.toggleSelection(first)
        viewModel.toggleSelection(second)

        XCTAssertEqual(viewModel.draft.people.count, 2)
        XCTAssertTrue(viewModel.draft.people.allSatisfy { $0.entryId < 0 })

        let firstSave = await viewModel.save()

        XCTAssertNil(firstSave)
        XCTAssertEqual(repository.createCount, 1)
        XCTAssertEqual(repository.addedRefs, [first.ref, second.ref])
        XCTAssertEqual(repository.removedEntryIDs, [])
        XCTAssertEqual(repository.reorderedEntryIDs, [])
        XCTAssertEqual(viewModel.draft.people.map(\.ref), [first.ref, second.ref])

        let retry = await viewModel.save()

        XCTAssertEqual(retry, 77)
        XCTAssertEqual(repository.createCount, 1)
        XCTAssertEqual(repository.addedRefs, [first.ref, second.ref, second.ref])
        XCTAssertEqual(repository.removedEntryIDs, [])
        XCTAssertEqual(repository.reorderedEntryIDs.count, 1)
        XCTAssertTrue(repository.reorderedEntryIDs[0].allSatisfy { $0 > 0 })
        XCTAssertTrue(viewModel.draft.people.allSatisfy { $0.entryId > 0 })
    }

    func testUndoDoesNotDuplicateAReaddedPersonWithAnotherEntryID() {
        let original = listPerson(
            entryId: 1,
            source: "tmdb",
            personId: "1",
            name: "First"
        )
        let viewModel = ListComposerViewModel(
            mode: .edit(peopleList([original])),
            listRepository: PickerListRepository(
                serverPeople: [original],
                canonicalRefs: [:],
                failuresByRef: [:]
            ),
            onUnauthorized: {}
        )
        viewModel.removePerson(entryId: original.entryId)
        let removal = viewModel.removedPerson
        viewModel.draft.people.append(
            listPerson(
                entryId: -1,
                source: "tmdb",
                personId: "1",
                name: "First"
            )
        )
        viewModel.removedPerson = removal

        viewModel.undoPersonRemoval()

        XCTAssertEqual(viewModel.draft.people.map(\.ref), [original.ref])
        XCTAssertNil(viewModel.removedPerson)
    }

    private func searchPerson(
        source: String,
        id: String,
        name: String
    ) -> PersonSearchResult {
        PersonSearchResult(
            ref: PersonRef(source: source, id: id),
            name: name,
            profileUrl: nil,
            knownForDepartment: "Acting"
        )
    }

    private func listPerson(
        entryId: Int,
        source: String,
        personId: String,
        name: String
    ) -> PersonListEntry {
        PersonListEntry(
            entryId: entryId,
            personId: personId,
            source: source,
            name: name,
            profileUrl: nil,
            knownForDepartment: "Acting",
            position: nil,
            dateAdded: "2026-07-31T00:00:00Z"
        )
    }

    private func peopleList(_ people: [PersonListEntry]) -> CustomListDetail {
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

private final class PickerPeopleRepository: PeopleRepository {
    let handler: (String) async throws -> PersonSearchResponse
    var queries: [String] = []

    init(handler: @escaping (String) async throws -> PersonSearchResponse) {
        self.handler = handler
    }

    func search(query: String) async throws -> PersonSearchResponse {
        queries.append(query)
        return try await handler(query)
    }

    func detail(ref: PersonRef) async throws -> PersonDetail {
        fatalError("Not used")
    }
}

@MainActor
private final class PickerListRepository: ListRepository {
    var serverPeople: [PersonListEntry]
    var canonicalRefs: [PersonRef: PersonRef]
    var failuresByRef: [PersonRef: Int]
    var createCount = 0
    var addedRefs: [PersonRef] = []
    var removedEntryIDs: [Int] = []
    var reorderedEntryIDs: [[Int]] = []

    private var nextEntryID = 100

    init(
        serverPeople: [PersonListEntry] = [],
        canonicalRefs: [PersonRef: PersonRef],
        failuresByRef: [PersonRef: Int]
    ) {
        self.serverPeople = serverPeople
        self.canonicalRefs = canonicalRefs
        self.failuresByRef = failuresByRef
    }

    func list(membershipFor ref: MediaRef?) async throws -> [CustomListSummary] { [] }
    func peopleLists(membershipFor ref: PersonRef) async throws -> [CustomListSummary] { [] }

    func detail(id: Int) async throws -> CustomListDetail {
        detail()
    }

    func create(_ request: CustomListWriteRequest) async throws -> CustomListSummary {
        createCount += 1
        return CustomListSummary(
            id: 77,
            name: request.name ?? "",
            slug: "people",
            description: request.description ?? "",
            visibility: request.visibility ?? "private",
            isRanked: request.isRanked ?? false,
            listType: request.listType ?? .media,
            owner: PeopleListPickerTests.owner,
            itemsCount: 0,
            peopleCount: serverPeople.count,
            entriesCount: serverPeople.count,
            likeCount: 0
        )
    }

    func update(id: Int, _ request: CustomListWriteRequest) async throws -> CustomListDetail {
        detail()
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
        fatalError("People lists must not load media")
    }

    func removeItem(listId: Int, itemId: Int) async throws {
        fatalError("People lists must not remove media")
    }

    func reorderItems(listId: Int, itemIds: [Int]) async throws -> CustomListDetail {
        fatalError("People lists must not reorder media")
    }

    func people(listId: Int, page: String?) async throws -> PagedResponse<PersonListEntry> {
        PagedResponse(
            count: serverPeople.count,
            next: nil,
            previous: nil,
            results: serverPeople
        )
    }

    func addPerson(listId: Int, ref: PersonRef) async throws -> PersonListEntry {
        addedRefs.append(ref)
        if let failures = failuresByRef[ref], failures > 0 {
            failuresByRef[ref] = failures - 1
            throw PickerListError.addFailed
        }

        let canonicalRef = canonicalRefs[ref] ?? ref
        if let existing = serverPeople.first(where: { $0.ref == canonicalRef }) {
            return existing
        }
        let entry = PersonListEntry(
            entryId: nextEntryID,
            personId: canonicalRef.id,
            source: canonicalRef.source,
            name: "Person \(canonicalRef.id)",
            profileUrl: nil,
            knownForDepartment: nil,
            position: nil,
            dateAdded: "2026-07-31T00:00:00Z"
        )
        nextEntryID += 1
        serverPeople.append(entry)
        return entry
    }

    func removePerson(listId: Int, entryId: Int) async throws {
        removedEntryIDs.append(entryId)
        serverPeople.removeAll { $0.entryId == entryId }
    }

    func reorderPeople(listId: Int, entryIds: [Int]) async throws -> CustomListDetail {
        reorderedEntryIDs.append(entryIds)
        let peopleByID = Dictionary(uniqueKeysWithValues: serverPeople.map { ($0.entryId, $0) })
        serverPeople = entryIds.compactMap { peopleByID[$0] }
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
            owner: PeopleListPickerTests.owner,
            itemsCount: 0,
            peopleCount: serverPeople.count,
            entriesCount: serverPeople.count,
            likeCount: 0,
            items: [],
            people: serverPeople
        )
    }
}

private enum PickerListError: LocalizedError {
    case addFailed

    var errorDescription: String? {
        "Add failed"
    }
}

private final class PeopleSearchURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!,
            Data(body.utf8)
        )
    }
}
