import Foundation

struct PersonRef: Codable, Hashable, Identifiable {
    let source: String
    let id: String
}

struct PersonDetail: Decodable, Identifiable, Hashable {
    let id: String
    let source: String
    let name: String
    let biography: String?
    let profileUrl: String?
    let knownForDepartment: String?
    let birthDate: String?
    let deathDate: String?
    let placeOfBirth: String?
    let popularity: Double?
    let filterOptions: MediaFilterOptionsResponse?
    let ratingPreparation: PersonRatingPreparation?
    let credits: PersonCredits

    init(
        id: String,
        source: String,
        name: String,
        biography: String? = nil,
        profileUrl: String? = nil,
        knownForDepartment: String? = nil,
        birthDate: String? = nil,
        deathDate: String? = nil,
        placeOfBirth: String? = nil,
        popularity: Double? = nil,
        filterOptions: MediaFilterOptionsResponse? = nil,
        ratingPreparation: PersonRatingPreparation? = nil,
        credits: PersonCredits
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.biography = biography
        self.profileUrl = profileUrl
        self.knownForDepartment = knownForDepartment
        self.birthDate = birthDate
        self.deathDate = deathDate
        self.placeOfBirth = placeOfBirth
        self.popularity = popularity
        self.filterOptions = filterOptions
        self.ratingPreparation = ratingPreparation
        self.credits = credits
    }

    var ref: PersonRef {
        PersonRef(source: source, id: id)
    }

    var filmography: [MediaSummary] {
        credits.cast
    }
}

enum PersonRatingPreparationState: String, Decodable, Hashable {
    case ready
    case pending
    case degraded
}

struct PersonRatingPreparation: Decodable, Hashable {
    let ratingSource: String
    let state: PersonRatingPreparationState
    let total: Int
    let ready: Int
    let unavailable: Int
    let failed: Int

    var processed: Int { ready + unavailable }
}

struct PersonCredits: Decodable, Hashable {
    let cast: [MediaSummary]

    init(cast: [MediaSummary] = []) {
        self.cast = cast
    }
}
