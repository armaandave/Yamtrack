import Foundation
@testable import Spine
import XCTest

@MainActor
final class PeopleListsContractTests: XCTestCase {
    func testTypedListModelsDecodePeopleAndPreserveLegacyMediaDefaults() throws {
        let legacy = try JSONDecoder.api.decode(
            CustomListSummary.self,
            from: Data(
                """
                {
                  "id": 1,
                  "name": "Movies",
                  "slug": "movies",
                  "description": "",
                  "visibility": "private",
                  "owner": {
                    "id": 1,
                    "username": "mobile",
                    "display_name": "Mobile",
                    "avatar_url": null
                  },
                  "items_count": 3,
                  "like_count": 0
                }
                """.utf8
            )
        )

        XCTAssertEqual(legacy.listType, .media)
        XCTAssertEqual(legacy.entriesCount, 3)
        XCTAssertEqual(legacy.peopleCount, 0)
        XCTAssertEqual(legacy.previewPeople, [])
        XCTAssertNil(legacy.hasPerson)
        XCTAssertNil(legacy.personEntryId)

        let summary = try JSONDecoder.api.decode(
            CustomListSummary.self,
            from: Data(
                """
                {
                  "id": 2,
                  "name": "Favorite actors",
                  "slug": "favorite-actors",
                  "description": "",
                  "visibility": "private",
                  "list_type": "people",
                  "has_person": true,
                  "person_entry_id": 31,
                  "owner": {
                    "id": 1,
                    "username": "mobile",
                    "display_name": "Mobile",
                    "avatar_url": null
                  },
                  "preview_items": [],
                  "preview_people": [\(Self.personEntryJSON)],
                  "items_count": 0,
                  "people_count": 1,
                  "like_count": 0
                }
                """.utf8
            )
        )
        XCTAssertEqual(summary.listType, .people)
        XCTAssertEqual(summary.hasPerson, true)
        XCTAssertEqual(summary.personEntryId, 31)
        XCTAssertEqual(summary.previewPeople.first?.personId, "819")
        XCTAssertEqual(summary.entriesCount, summary.itemsCount)

        let people = try JSONDecoder.api.decode(
            CustomListDetail.self,
            from: Data(
                """
                {
                  "id": 2,
                  "name": "Favorite actors",
                  "slug": "favorite-actors",
                  "description": "",
                  "visibility": "private",
                  "is_ranked": true,
                  "list_type": "people",
                  "owner": {
                    "id": 1,
                    "username": "mobile",
                    "display_name": "Mobile",
                    "avatar_url": null
                  },
                  "items_count": 0,
                  "people_count": 1,
                  "entries_count": 1,
                  "like_count": 0,
                  "items": [],
                  "people": [
                    {
                      "entry_id": 31,
                      "id": "819",
                      "source": "tmdb",
                      "name": "Edward Norton",
                      "profile_url": null,
                      "known_for_department": null,
                      "position": 1,
                      "date_added": "2026-07-28T04:00:00Z"
                    }
                  ]
                }
                """.utf8
            )
        )

        let entry = try XCTUnwrap(people.people.first)
        XCTAssertEqual(people.listType, .people)
        XCTAssertEqual(people.itemsCount, 0)
        XCTAssertEqual(people.peopleCount, 1)
        XCTAssertEqual(people.entriesCount, 1)
        XCTAssertEqual(entry.entryId, 31)
        XCTAssertEqual(entry.id, 31)
        XCTAssertEqual(entry.personId, "819")
        XCTAssertEqual(entry.ref, PersonRef(source: "tmdb", id: "819"))
        XCTAssertNil(entry.profileUrl)
        XCTAssertNil(entry.knownForDepartment)
        XCTAssertEqual(entry.position, 1)
    }

    func testListWriteEncodesTypeOnlyWhenProvided() throws {
        let createData = try JSONEncoder.api.encode(
            CustomListWriteRequest(
                name: "Favorite actors",
                description: "",
                visibility: "private",
                isRanked: false,
                listType: .people
            )
        )
        let create = try XCTUnwrap(
            JSONSerialization.jsonObject(with: createData) as? [String: Any]
        )
        XCTAssertEqual(create["list_type"] as? String, "people")

        let updateData = try JSONEncoder.api.encode(
            CustomListWriteRequest(
                name: "Actors",
                description: nil,
                visibility: nil,
                isRanked: nil
            )
        )
        let update = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updateData) as? [String: Any]
        )
        XCTAssertNil(update["list_type"])
    }

    func testPersonRefsRoundTripForEverySupportedSource() throws {
        let sources = [
            "tmdb",
            "hardcover",
            "openlibrary",
            "musicbrainz",
            "mal",
            "mangaupdates",
            "anilist",
        ]

        for (index, source) in sources.enumerated() {
            let original = PersonRef(source: source, id: "person-\(index)")
            let decodedRef = try JSONDecoder.api.decode(
                PersonRef.self,
                from: JSONEncoder.api.encode(original)
            )
            XCTAssertEqual(decodedRef, original, source)

            let entry = try JSONDecoder.api.decode(
                PersonListEntry.self,
                from: Data(
                    """
                    {
                      "entry_id": \(index + 1),
                      "id": "\(original.id)",
                      "source": "\(source)",
                      "name": "Person \(index)",
                      "profile_url": null,
                      "known_for_department": null,
                      "position": null,
                      "date_added": "2026-07-28T04:00:00Z"
                    }
                    """.utf8
                )
            )
            XCTAssertEqual(entry.ref, original, source)
        }
    }

    func testPeopleListRepositorySendsTypedRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PeopleListsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = KeychainTokenStore.shared
        tokenStore.accessToken = "people-list-access"
        defer {
            tokenStore.clear()
            PeopleListsURLProtocol.handler = nil
        }

        let repository = APIListRepository(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!,
                tokenProvider: tokenStore,
                session: session
            )
        )
        var requests: [String] = []
        var addRequestCount = 0
        let personEntryJSON = Self.personEntryJSON
        let peopleDetailJSON = Self.peopleDetailJSON

        PeopleListsURLProtocol.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer people-list-access"
            )
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            let query = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []

            if method == "GET",
               path.hasSuffix("/lists/") || path.hasSuffix("/lists") {
                let listType = query.first { $0.name == "list_type" }?.value
                if listType == "all" {
                    requests.append("all")
                } else {
                    XCTAssertEqual(listType, "people")
                    XCTAssertEqual(
                        query.first { $0.name == "person_ref[source]" }?.value,
                        "tmdb"
                    )
                    XCTAssertEqual(
                        query.first { $0.name == "person_ref[id]" }?.value,
                        "819"
                    )
                    requests.append("membership")
                }
                return PeopleListsURLProtocol.response(
                    request,
                    status: 200,
                    body: #"{"count":0,"next":null,"previous":null,"results":[]}"#
                )
            }

            if method == "GET",
               path.hasSuffix("/lists/9/people/") || path.hasSuffix("/lists/9/people") {
                XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
                requests.append("page")
                return PeopleListsURLProtocol.response(
                    request,
                    status: 200,
                    body: """
                    {
                      "count": 1,
                      "next": null,
                      "previous": null,
                      "results": [\(personEntryJSON)]
                    }
                    """
                )
            }

            if method == "POST",
               path.hasSuffix("/lists/9/people/") || path.hasSuffix("/lists/9/people") {
                let body = try PeopleListsURLProtocol.bodyJSON(request)
                let ref = try XCTUnwrap(body["ref"] as? [String: Any])
                XCTAssertEqual(ref["source"] as? String, "tmdb")
                XCTAssertEqual(ref["id"] as? String, "819")
                requests.append("add")
                addRequestCount += 1
                return PeopleListsURLProtocol.response(
                    request,
                    status: addRequestCount == 1 ? 201 : 200,
                    body: """
                    {"created":\(addRequestCount == 1),"person":\(personEntryJSON)}
                    """
                )
            }

            if method == "DELETE",
               path.hasSuffix("/lists/9/people/31/") || path.hasSuffix("/lists/9/people/31") {
                requests.append("remove")
                return PeopleListsURLProtocol.response(request, status: 204)
            }

            if method == "PATCH",
               path.hasSuffix("/lists/9/people/reorder/") || path.hasSuffix("/lists/9/people/reorder") {
                let body = try PeopleListsURLProtocol.bodyJSON(request)
                XCTAssertEqual(body["entry_ids"] as? [Int], [31])
                requests.append("reorder")
                return PeopleListsURLProtocol.response(
                    request,
                    status: 200,
                    body: peopleDetailJSON
                )
            }

            XCTFail("Unexpected request \(method) \(request.url?.absoluteString ?? "")")
            return PeopleListsURLProtocol.response(request, status: 500)
        }

        _ = try await repository.list()
        _ = try await repository.peopleLists(
            membershipFor: PersonRef(source: "tmdb", id: "819")
        )
        let page = try await repository.people(listId: 9, page: "2")
        let added = try await repository.addPerson(
            listId: 9,
            ref: PersonRef(source: "tmdb", id: "819")
        )
        let duplicate = try await repository.addPerson(
            listId: 9,
            ref: PersonRef(source: "tmdb", id: "819")
        )
        try await repository.removePerson(listId: 9, entryId: 31)
        let reordered = try await repository.reorderPeople(
            listId: 9,
            entryIds: [31]
        )

        XCTAssertEqual(page.results.first?.entryId, 31)
        XCTAssertEqual(added.ref, PersonRef(source: "tmdb", id: "819"))
        XCTAssertEqual(duplicate.ref, PersonRef(source: "tmdb", id: "819"))
        XCTAssertEqual(reordered.people.first?.entryId, 31)
        XCTAssertEqual(
            requests,
            ["all", "membership", "page", "add", "add", "remove", "reorder"]
        )
    }

    private static let personEntryJSON = """
    {
      "entry_id": 31,
      "id": "819",
      "source": "tmdb",
      "name": "Edward Norton",
      "profile_url": "https://example.com/person.jpg",
      "known_for_department": "Acting",
      "position": 1,
      "date_added": "2026-07-28T04:00:00Z"
    }
    """

    private static let peopleDetailJSON = """
    {
      "id": 9,
      "name": "Favorite actors",
      "slug": "favorite-actors",
      "description": "",
      "visibility": "private",
      "is_ranked": true,
      "list_type": "people",
      "owner": {
        "id": 1,
        "username": "mobile",
        "display_name": "Mobile",
        "avatar_url": null
      },
      "items_count": 0,
      "people_count": 1,
      "entries_count": 1,
      "like_count": 0,
      "items": [],
      "people": [\(personEntryJSON)]
    }
    """
}

private final class PeopleListsURLProtocol: URLProtocol {
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
        body: String = ""
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

    static func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 1_024)
                if count <= 0 {
                    break
                }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            data = Data()
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
