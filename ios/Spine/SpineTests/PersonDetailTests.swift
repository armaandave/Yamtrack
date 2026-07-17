import XCTest
@testable import Spine

final class PersonDetailTests: XCTestCase {
    func testPersonDetailDecodesExpectedAPIShape() throws {
        let json = """
        {
          "id": "819",
          "source": "tmdb",
          "name": "Edward Norton",
          "biography": "An actor biography.",
          "profile_url": "https://image.tmdb.org/t/p/h632/profile.jpg",
          "known_for_department": "Acting",
          "birth_date": "1969-08-18",
          "death_date": null,
          "place_of_birth": "Boston, Massachusetts, USA",
          "popularity": 42.7,
          "credits": {
            "cast": [
              {
                "ref": {
                  "item_id": null,
                  "source": "tmdb",
                  "media_type": "movie",
                  "media_id": "550",
                  "season_number": null,
                  "episode_number": null
                },
                "title": "Fight Club",
                "subtitle": "1999",
                "overview": null,
                "image_url": "https://example.com/poster.jpg",
                "poster_url": "https://example.com/poster.jpg",
                "release_date": "1999-10-15",
                "default_source": "tmdb",
                "user_state": null
              }
            ]
          }
        }
        """

        let detail = try JSONDecoder.api.decode(PersonDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.ref, PersonRef(source: "tmdb", id: "819"))
        XCTAssertEqual(detail.name, "Edward Norton")
        XCTAssertEqual(detail.profileUrl, "https://image.tmdb.org/t/p/h632/profile.jpg")
        XCTAssertEqual(detail.knownForDepartment, "Acting")
        XCTAssertEqual(detail.filmography.map(\.title), ["Fight Club"])
    }

    func testPersonDetailDecodesHardcoverAuthorBooks() throws {
        let json = """
        {
          "id": "80626",
          "source": "hardcover",
          "name": "Dan Wells",
          "biography": "Author biography.",
          "profile_url": "https://example.com/dan.jpg",
          "known_for_department": "Author",
          "birth_date": "1977-03-04",
          "death_date": null,
          "place_of_birth": null,
          "popularity": 12,
          "credits": {
            "cast": [
              {
                "ref": {
                  "item_id": null,
                  "source": "hardcover",
                  "media_type": "book",
                  "media_id": "328491",
                  "season_number": null,
                  "episode_number": null
                },
                "title": "I Am Not a Serial Killer",
                "subtitle": "2009",
                "overview": null,
                "image_url": "https://example.com/book.jpg",
                "poster_url": "https://example.com/book.jpg",
                "release_date": "2009-03-30",
                "default_source": "hardcover",
                "user_state": null
              }
            ]
          }
        }
        """

        let detail = try JSONDecoder.api.decode(PersonDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.ref, PersonRef(source: "hardcover", id: "80626"))
        XCTAssertEqual(detail.knownForDepartment, "Author")
        XCTAssertEqual(detail.filmography.first?.ref.mediaType, "book")
        XCTAssertEqual(detail.filmography.first?.title, "I Am Not a Serial Killer")
    }

    func testPersonDetailDecodesMusicBrainzArtistReleases() throws {
        let json = """
        {
          "id": "artist-1",
          "source": "musicbrainz",
          "name": "Artist",
          "biography": "Artist biography.",
          "profile_url": "https://example.com/artist.jpg",
          "known_for_department": "Artist",
          "birth_date": "1988",
          "death_date": null,
          "place_of_birth": "Cleveland",
          "popularity": null,
          "credits": {
            "cast": [
              {
                "ref": {
                  "item_id": null,
                  "source": "musicbrainz",
                  "media_type": "music",
                  "media_id": "release-group-1",
                  "season_number": null,
                  "episode_number": null
                },
                "title": "Album",
                "subtitle": "2005",
                "overview": null,
                "image_url": "https://example.com/album.jpg",
                "poster_url": "https://example.com/album.jpg",
                "release_date": "2005",
                "genres": ["Industrial Rock"],
                "roles": ["Artist"],
                "credit_roles": ["Artist"],
                "default_source": "musicbrainz",
                "user_state": null
              }
            ]
          }
        }
        """

        let detail = try JSONDecoder.api.decode(PersonDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.ref, PersonRef(source: "musicbrainz", id: "artist-1"))
        XCTAssertEqual(detail.knownForDepartment, "Artist")
        XCTAssertEqual(detail.filmography.first?.ref.source, "musicbrainz")
        XCTAssertEqual(detail.filmography.first?.ref.mediaType, "music")
        XCTAssertEqual(detail.filmography.first?.ref.mediaId, "release-group-1")
        XCTAssertEqual(detail.filmography.first?.creditRoles, ["Artist"])
        XCTAssertEqual(MediaTypeTheme.theme(for: "music").artworkOrientation, .square)
    }

    func testMusicFilmographyUsesDiscographyCopyAndArtistRole() {
        let release = mediaSummary(
            id: "release-group-1",
            title: "Album",
            source: "musicbrainz",
            mediaType: "music",
            creditRoles: ["Artist"]
        )

        XCTAssertEqual(FilmographyType.available(in: [release]), [.music])
        XCTAssertEqual(FilmographyType.music.title, "Music")
        XCTAssertEqual(FilmographyType.music.sectionTitle, "Discography")
        XCTAssertEqual(FilmographyType.music.creditNoun(count: 1), "release")
        XCTAssertEqual(FilmographyType.music.creditNoun(count: 2), "releases")
        XCTAssertEqual(
            FilmographyCreditGroup.groups(from: [release], knownForDepartment: "Artist").map(\.role),
            ["Artist"]
        )
    }

    func testCreditGroupsPutKnownDepartmentRoleFirst() {
        let filmography = [
            mediaSummary(id: "1", title: "Acting One", creditRoles: ["Actor"]),
            mediaSummary(id: "2", title: "Acting Two", creditRoles: ["Actor"]),
            mediaSummary(id: "3", title: "Producing One", creditRoles: ["Producer"]),
            mediaSummary(id: "4", title: "Producing Two", creditRoles: ["Producer"]),
            mediaSummary(id: "5", title: "Directing One", creditRoles: ["Director"]),
        ]

        let groups = FilmographyCreditGroup.groups(
            from: filmography,
            knownForDepartment: "Directing"
        )

        XCTAssertEqual(groups.map(\.role), ["Director", "Actor", "Producer"])
    }

    func testCreditGroupsFallBackToCountThenAlphabeticalOrder() {
        let filmography = [
            mediaSummary(id: "1", title: "Directing One", creditRoles: ["Director"]),
            mediaSummary(id: "2", title: "Acting One", creditRoles: ["Actor"]),
            mediaSummary(id: "3", title: "Producing One", creditRoles: ["Producer"]),
            mediaSummary(id: "4", title: "Producing Two", creditRoles: ["Producer"]),
        ]

        let groups = FilmographyCreditGroup.groups(
            from: filmography,
            knownForDepartment: "Sound"
        )

        XCTAssertEqual(groups.map(\.role), ["Producer", "Actor", "Director"])
    }

    @MainActor
    func testPersonDetailViewModelLoadsAndDeduplicatesFilmography() async {
        let ref = PersonRef(source: "tmdb", id: "819")
        let repository = ScriptedPeopleRepository(result: .success(personDetail(filmography: [
            mediaSummary(id: "550", title: "Fight Club"),
            mediaSummary(id: "550", title: "Fight Club Duplicate"),
            mediaSummary(id: "680", title: "Pulp Fiction"),
        ])))
        let viewModel = PersonDetailViewModel(ref: ref, peopleRepository: repository, onUnauthorized: {})

        await viewModel.load()

        XCTAssertEqual(repository.requests, [ref])
        XCTAssertEqual(viewModel.detail?.name, "Edward Norton")
        XCTAssertEqual(viewModel.filmography.map(\.title), ["Fight Club", "Pulp Fiction"])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testPersonDetailViewModelKeepsFilterOptionsAfterFilteredReload() async {
        let ref = PersonRef(source: "tmdb", id: "819")
        let repository = ScriptedPeopleRepository(results: [
            .success(personDetail(filmography: [
                mediaSummary(id: "1", title: "Drama", genres: ["Drama"]),
                mediaSummary(id: "2", title: "Comedy", genres: ["Comedy"]),
            ])),
            .success(personDetail(filmography: [
                mediaSummary(id: "1", title: "Drama", genres: ["Drama"]),
            ])),
        ])
        let viewModel = PersonDetailViewModel(ref: ref, peopleRepository: repository, onUnauthorized: {})

        await viewModel.load()
        viewModel.filter.excludedGenres = ["Comedy"]
        await viewModel.load()

        XCTAssertEqual(viewModel.filmography.map(\.title), ["Drama"])
        XCTAssertEqual(viewModel.filterOptions.genres.map(\.value), ["Comedy", "Drama"])
    }

    @MainActor
    func testPersonDetailViewModelSupportsEmptyFilmography() async {
        let repository = ScriptedPeopleRepository(result: .success(personDetail(filmography: [])))
        let viewModel = PersonDetailViewModel(
            ref: PersonRef(source: "tmdb", id: "819"),
            peopleRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()

        XCTAssertNotNil(viewModel.detail)
        XCTAssertEqual(viewModel.filmography, [])
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPersonDetailViewModelStoresError() async {
        let repository = ScriptedPeopleRepository(result: .failure(APIError.httpStatus(500, "Server error")))
        let viewModel = PersonDetailViewModel(
            ref: PersonRef(source: "tmdb", id: "819"),
            peopleRepository: repository,
            onUnauthorized: {}
        )

        await viewModel.load()

        XCTAssertNil(viewModel.detail)
        XCTAssertEqual(viewModel.filmography, [])
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testPersonDetailViewModelCallsUnauthorizedHandler() async {
        var didCallUnauthorized = false
        let repository = ScriptedPeopleRepository(result: .failure(APIError.unauthorized))
        let viewModel = PersonDetailViewModel(
            ref: PersonRef(source: "tmdb", id: "819"),
            peopleRepository: repository,
            onUnauthorized: { didCallUnauthorized = true }
        )

        await viewModel.load()

        XCTAssertTrue(didCallUnauthorized)
        XCTAssertNil(viewModel.detail)
    }

    private func personDetail(filmography: [MediaSummary]) -> PersonDetail {
        PersonDetail(
            id: "819",
            source: "tmdb",
            name: "Edward Norton",
            biography: "An actor biography.",
            profileUrl: "https://image.tmdb.org/t/p/h632/profile.jpg",
            knownForDepartment: "Acting",
            birthDate: "1969-08-18",
            deathDate: nil,
            placeOfBirth: "Boston",
            popularity: 42.7,
            credits: PersonCredits(cast: filmography)
        )
    }

    private func mediaSummary(
        id: String,
        title: String,
        source: String = "tmdb",
        mediaType: String = "movie",
        genres: [String] = [],
        creditRoles: [String] = []
    ) -> MediaSummary {
        MediaSummary(
            ref: MediaRef(
                itemId: nil,
                source: source,
                mediaType: mediaType,
                mediaId: id,
                seasonNumber: nil,
                episodeNumber: nil
            ),
            title: title,
            posterUrl: "https://example.com/\(id).jpg",
            genres: genres,
            creditRoles: creditRoles,
            defaultSource: source
        )
    }
}

private final class ScriptedPeopleRepository: PeopleRepository {
    let results: [Result<PersonDetail, Error>]
    var requests: [PersonRef] = []

    init(result: Result<PersonDetail, Error>) {
        self.results = [result]
    }

    init(results: [Result<PersonDetail, Error>]) {
        self.results = results
    }

    func detail(ref: PersonRef) async throws -> PersonDetail {
        requests.append(ref)
        return try results[min(requests.count - 1, results.count - 1)].get()
    }
}
