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
          "series": [
            {
              "id": "1185",
              "source": "hardcover",
              "name": "John Cleaver",
              "book_count": 3,
              "poster_urls": [
                "https://example.com/one.jpg",
                "https://example.com/two.jpg"
              ]
            }
          ],
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
        XCTAssertEqual(detail.bookSeries.first?.ref, SeriesRef(source: "hardcover", id: "1185"))
        XCTAssertEqual(detail.bookSeries.first?.posterUrls.count, 2)
    }

    func testBookSeriesDetailDecodesPrimaryBookOrder() throws {
        let json = """
        {
          "id": "1185",
          "source": "hardcover",
          "name": "Harry Potter",
          "book_count": 2,
          "books": [
            {
              "ref": {
                "item_id": null,
                "source": "hardcover",
                "media_type": "book",
                "media_id": "328491",
                "season_number": null,
                "episode_number": null
              },
              "title": "Book One",
              "position": 1
            },
            {
              "ref": {
                "item_id": null,
                "source": "hardcover",
                "media_type": "book",
                "media_id": "429306",
                "season_number": null,
                "episode_number": null
              },
              "title": "Book Two",
              "position": 2
            }
          ]
        }
        """

        let detail = try JSONDecoder.api.decode(SeriesDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.name, "Harry Potter")
        XCTAssertEqual(detail.books.map(\.position), [1, 2])
    }

    func testSeriesDetailDecodesMoviePayload() throws {
        let json = """
        {
          "series_id": "10",
          "source": "tmdb",
          "media_type": "movie",
          "name": "The Example Collection",
          "item_count": 1,
          "items": [
            {
              "ref": {
                "item_id": null,
                "source": "tmdb",
                "media_type": "movie",
                "media_id": "11",
                "season_number": null,
                "episode_number": null
              },
              "title": "Movie One"
            }
          ]
        }
        """

        let detail = try JSONDecoder.api.decode(SeriesDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.seriesId, "10")
        XCTAssertEqual(detail.mediaType, "movie")
        XCTAssertEqual(detail.itemCount, 1)
        XCTAssertEqual(detail.items.first?.ref.mediaType, "movie")
    }

    func testSeriesDetailDecodesGamePayload() throws {
        let json = """
        {
          "series_id": "500",
          "source": "igdb",
          "media_type": "game",
          "name": "Space Collection",
          "item_count": 1,
          "items": [
            {
              "ref": {
                "item_id": null,
                "source": "igdb",
                "media_type": "game",
                "media_id": "1020",
                "season_number": null,
                "episode_number": null
              },
              "title": "Space Game"
            }
          ]
        }
        """

        let detail = try JSONDecoder.api.decode(SeriesDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.seriesId, "500")
        XCTAssertEqual(detail.mediaType, "game")
        XCTAssertEqual(detail.itemCount, 1)
        XCTAssertEqual(detail.items.first?.ref.mediaType, "game")
    }

    func testAnimePersonAndSeriesDecodeGenericSeriesFields() throws {
        let personJSON = """
        {
          "id": "950",
          "source": "anilist",
          "name": "Voice Actor",
          "series": [
            {
              "id": "16498",
              "source": "mal",
              "media_type": "anime",
              "name": "Attack on Titan",
              "item_count": 4,
              "poster_urls": ["https://example.com/aot.jpg"]
            }
          ],
          "credits": { "cast": [] }
        }
        """
        let seriesJSON = """
        {
          "series_id": "16498",
          "source": "mal",
          "media_type": "anime",
          "name": "Attack on Titan",
          "item_count": 2,
          "items": [
            {
              "ref": {
                "item_id": null,
                "source": "mal",
                "media_type": "anime",
                "media_id": "16498",
                "season_number": null,
                "episode_number": null
              },
              "title": "Shingeki no Kyojin",
              "display_title": "Attack on Titan",
              "subtitle": "Anime · 2013 · 25 episodes",
              "position": 1
            }
          ]
        }
        """

        let person = try JSONDecoder.api.decode(PersonDetail.self, from: Data(personJSON.utf8))
        let detail = try JSONDecoder.api.decode(SeriesDetail.self, from: Data(seriesJSON.utf8))

        XCTAssertEqual(person.series(for: "anime").first?.ref, SeriesRef(source: "mal", id: "16498", mediaType: "anime"))
        XCTAssertEqual(person.series(for: "anime").first?.itemCount, 4)
        XCTAssertTrue(person.bookSeries.isEmpty)
        XCTAssertEqual(detail.mediaType, "anime")
        XCTAssertEqual(detail.items.first?.displayTitle, "Attack on Titan")
        XCTAssertEqual(detail.items.first?.subtitle, "Anime · 2013 · 25 episodes")
        XCTAssertEqual(detail.items.first?.position, 1)
    }

    func testPersonDetailDecodesMusicBrainzArtistReleases() throws {
        let json = """
        {
          "id": "artist-1",
          "source": "musicbrainz",
          "name": "Artist",
          "biography": null,
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
                "credit_roles": ["Albums"],
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
        XCTAssertNil(detail.biography)
        XCTAssertEqual(detail.filmography.first?.creditRoles, ["Albums"])
        XCTAssertEqual(MediaTypeTheme.theme(for: "music").artworkOrientation, .square)
    }

    func testPersonDetailDecodesDynamicSortOptionsAndPreparation() throws {
        let json = """
        {
          "id": "author-1",
          "source": "hardcover",
          "name": "Author",
          "filter_options": {
            "sorts": [{"value": "rating:futurebooks", "label": "Future Books Rating"}],
            "genres": [],
            "languages": [],
            "platforms": [],
            "years": []
          },
          "rating_preparation": {
            "rating_source": "futurebooks",
            "state": "pending",
            "total": 10,
            "ready": 4,
            "unavailable": 2,
            "failed": 0
          },
          "credits": {"cast": []}
        }
        """

        let detail = try JSONDecoder.api.decode(PersonDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.filterOptions?.sorts.first?.value, "rating:futurebooks")
        XCTAssertEqual(detail.filterOptions?.sorts.first?.label, "Future Books Rating")
        XCTAssertEqual(detail.ratingPreparation?.state, .pending)
        XCTAssertEqual(detail.ratingPreparation?.processed, 6)
    }

    func testMusicFilmographyUsesDiscographyCopyAndReleaseSections() {
        let releases = [
            mediaSummary(id: "single", title: "Single", source: "musicbrainz", mediaType: "music", creditRoles: ["Singles"]),
            mediaSummary(id: "compilation", title: "Compilation", source: "musicbrainz", mediaType: "music", creditRoles: ["Compilations"]),
            mediaSummary(id: "album", title: "Album", source: "musicbrainz", mediaType: "music", creditRoles: ["Albums"]),
        ]

        XCTAssertEqual(FilmographyType.available(in: releases), [.music])
        XCTAssertEqual(FilmographyType.music.title, "Music")
        XCTAssertEqual(FilmographyType.music.sectionTitle, "Discography")
        XCTAssertEqual(FilmographyType.music.creditNoun(count: 1), "release")
        XCTAssertEqual(FilmographyType.music.creditNoun(count: 2), "releases")
        XCTAssertEqual(
            FilmographyCreditGroup.groups(from: releases, knownForDepartment: "Artist").map(\.role),
            ["Albums", "Singles", "Compilations"]
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

    @MainActor
    func testPersonDetailViewModelPollsPendingPreparationUntilReady() async throws {
        let filterOptions = MediaFilterOptionsResponse(
            sorts: [FilterChoice(value: "rating:imdb", label: "IMDb Rating")],
            genres: [],
            languages: [],
            years: []
        )
        let pending = PersonRatingPreparation(
            ratingSource: "imdb",
            state: .pending,
            total: 2,
            ready: 1,
            unavailable: 0,
            failed: 0
        )
        let ready = PersonRatingPreparation(
            ratingSource: "imdb",
            state: .ready,
            total: 2,
            ready: 2,
            unavailable: 0,
            failed: 0
        )
        let repository = ScriptedPeopleRepository(results: [
            .success(personDetail(
                filmography: [mediaSummary(id: "1", title: "Partial")],
                filterOptions: filterOptions,
                ratingPreparation: pending
            )),
            .success(personDetail(
                filmography: [
                    mediaSummary(id: "2", title: "Highest"),
                    mediaSummary(id: "1", title: "Partial"),
                ],
                filterOptions: filterOptions,
                ratingPreparation: ready
            )),
        ])
        let viewModel = PersonDetailViewModel(
            ref: PersonRef(source: "tmdb", id: "819"),
            peopleRepository: repository,
            onUnauthorized: {},
            pollInterval: .milliseconds(1),
            maxPollAttempts: 2
        )
        viewModel.filter.sort = MediaFilterSort(rawValue: "rating:imdb")

        await viewModel.load()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(viewModel.detail?.ratingPreparation?.state, .ready)
        XCTAssertEqual(viewModel.filmography.map(\.title), ["Highest", "Partial"])
        XCTAssertEqual(repository.filters.map { $0.sort?.rawValue }, ["rating:imdb", "rating:imdb"])
        XCTAssertFalse(viewModel.isPreparationPolling)
    }

    @MainActor
    func testPersonDetailViewModelCancelsPreparationPolling() async throws {
        let pending = PersonRatingPreparation(
            ratingSource: "imdb",
            state: .pending,
            total: 1,
            ready: 0,
            unavailable: 0,
            failed: 0
        )
        let repository = ScriptedPeopleRepository(result: .success(personDetail(
            filmography: [mediaSummary(id: "1", title: "Movie")],
            ratingPreparation: pending
        )))
        let viewModel = PersonDetailViewModel(
            ref: PersonRef(source: "tmdb", id: "819"),
            peopleRepository: repository,
            onUnauthorized: {},
            pollInterval: .milliseconds(20),
            maxPollAttempts: 10
        )
        viewModel.filter.sort = MediaFilterSort(rawValue: "rating:imdb")

        await viewModel.load()
        viewModel.cancelPreparation()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(repository.requests.count, 1)
        XCTAssertFalse(viewModel.isPreparationPolling)
    }

    @MainActor
    func testPersonDetailViewModelRejectsStaleSortResponse() async throws {
        let repository = DelayedPersonRepository(
            slow: personDetail(filmography: [mediaSummary(id: "old", title: "Old")]),
            fast: personDetail(filmography: [mediaSummary(id: "new", title: "New")])
        )
        let viewModel = PersonDetailViewModel(
            ref: PersonRef(source: "tmdb", id: "819"),
            peopleRepository: repository,
            onUnauthorized: {}
        )
        viewModel.filter.sort = MediaFilterSort(rawValue: "rating:imdb")
        let staleLoad = Task { await viewModel.load() }
        try await Task.sleep(for: .milliseconds(5))
        viewModel.filter.sort = MediaFilterSort(rawValue: "rating:tmdb")

        await viewModel.load()
        await staleLoad.value

        XCTAssertEqual(viewModel.filmography.map(\.title), ["New"])
    }

    private func personDetail(
        filmography: [MediaSummary],
        filterOptions: MediaFilterOptionsResponse? = nil,
        ratingPreparation: PersonRatingPreparation? = nil
    ) -> PersonDetail {
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
            filterOptions: filterOptions,
            ratingPreparation: ratingPreparation,
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
    var filters: [MediaFilterState] = []

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

    func detail(ref: PersonRef, filter: MediaFilterState) async throws -> PersonDetail {
        filters.append(filter)
        return try await detail(ref: ref)
    }
}

private final class DelayedPersonRepository: PeopleRepository {
    let slow: PersonDetail
    let fast: PersonDetail

    init(slow: PersonDetail, fast: PersonDetail) {
        self.slow = slow
        self.fast = fast
    }

    func detail(ref: PersonRef) async throws -> PersonDetail {
        fast
    }

    func detail(ref: PersonRef, filter: MediaFilterState) async throws -> PersonDetail {
        if filter.sort?.rawValue == "rating:imdb" {
            try await Task.sleep(for: .milliseconds(40))
            return slow
        }
        try await Task.sleep(for: .milliseconds(1))
        return fast
    }
}
