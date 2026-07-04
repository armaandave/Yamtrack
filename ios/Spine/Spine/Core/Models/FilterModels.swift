import Foundation

enum MediaFilterSort: String, Codable, CaseIterable, Identifiable {
    case title
    case releaseDate = "release_date"
    case yourRating = "your_rating"
    case averageRating = "average_rating"
    case letterboxdRating = "letterboxd_rating"
    case imdbRating = "imdb_rating"
    case rottenTomatoesRating = "rotten_tomatoes_rating"
    case consumedAt = "consumed_at"
    case dateAdded = "date_added"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .releaseDate: "Release Date"
        case .yourRating: "Your Rating"
        case .averageRating: "Average Rating"
        case .letterboxdRating: "Letterboxd Rating"
        case .imdbRating: "IMDb Rating"
        case .rottenTomatoesRating: "Rotten Tomatoes"
        case .consumedAt: "Watched Date"
        case .dateAdded: "Date Added"
        }
    }
}

enum MediaFilterDirection: String, Codable, CaseIterable, Identifiable {
    case asc
    case desc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .asc: "Ascending"
        case .desc: "Descending"
        }
    }
}

enum MediaFilterScope: Equatable {
    case tracking(mediaType: String)
    case diary
    case list(id: Int)
    case person(ref: PersonRef)

    var optionsQueryItems: [URLQueryItem]? {
        switch self {
        case let .tracking(mediaType):
            [
                URLQueryItem(name: "scope", value: "tracking"),
                URLQueryItem(name: "media_type", value: mediaType),
            ]
        case .diary:
            [URLQueryItem(name: "scope", value: "diary")]
        case let .list(id):
            [
                URLQueryItem(name: "scope", value: "list"),
                URLQueryItem(name: "list_id", value: String(id)),
            ]
        case .person:
            nil
        }
    }
}

struct MediaFilterState: Equatable {
    var sort: MediaFilterSort?
    var direction: MediaFilterDirection?
    var q = ""
    var mediaType: String?
    var status: String?
    var itemId: Int?
    var year: Int?
    var yearMin: Int?
    var yearMax: Int?
    var releaseStatus: String?
    var length: String?
    var genres: [String] = []
    var languages: [String] = []
    var excludedGenres: [String] = []
    var excludedLanguages: [String] = []
    var ratingMin: Decimal?
    var ratingMax: Decimal?
    var watchedFrom: Date?
    var watchedTo: Date?
    var tag: String?
    var hasReview = false
    var liked = false

    var isActive: Bool {
        activeCount > 0
    }

    var activeCount: Int {
        var count = 0
        if sort != nil { count += 1 }
        if !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if mediaType != nil { count += 1 }
        if status != nil { count += 1 }
        if itemId != nil { count += 1 }
        if year != nil || yearMin != nil || yearMax != nil { count += 1 }
        if releaseStatus != nil { count += 1 }
        if length != nil { count += 1 }
        if !genres.isEmpty || !excludedGenres.isEmpty { count += 1 }
        if !languages.isEmpty || !excludedLanguages.isEmpty { count += 1 }
        if ratingMin != nil || ratingMax != nil { count += 1 }
        if watchedFrom != nil || watchedTo != nil { count += 1 }
        if tag?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { count += 1 }
        if hasReview { count += 1 }
        if liked { count += 1 }
        return count
    }

    func queryItems(page: String? = nil, mediaType fallbackMediaType: String? = nil) -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        if let fallbackMediaType {
            items.append(URLQueryItem(name: "media_type", value: fallbackMediaType))
        } else if let mediaType {
            items.append(URLQueryItem(name: "media_type", value: mediaType))
        }
        appendTrimmed("q", q, to: &items)
        append("sort", sort?.rawValue, to: &items)
        append("direction", direction?.rawValue, to: &items)
        append("status", status, to: &items)
        append("item_id", itemId.map(String.init), to: &items)
        append("year", year.map(String.init), to: &items)
        append("year_min", yearMin.map(String.init), to: &items)
        append("year_max", yearMax.map(String.init), to: &items)
        append("release_status", releaseStatus, to: &items)
        append("length", length, to: &items)
        genres.forEach { append("genre", $0, to: &items) }
        languages.forEach { append("language", $0, to: &items) }
        excludedGenres.forEach { append("exclude_genre", $0, to: &items) }
        excludedLanguages.forEach { append("exclude_language", $0, to: &items) }
        append("rating_min", ratingMin.map(Self.string), to: &items)
        append("rating_max", ratingMax.map(Self.string), to: &items)
        append("watched_from", watchedFrom.map(Self.dateString), to: &items)
        append("watched_to", watchedTo.map(Self.dateString), to: &items)
        appendTrimmed("tag", tag ?? "", to: &items)
        if hasReview {
            items.append(URLQueryItem(name: "has_review", value: "true"))
        }
        if liked {
            items.append(URLQueryItem(name: "liked", value: "true"))
        }
        if let page {
            items.append(URLQueryItem(name: "page", value: page))
        }
        return items
    }

    mutating func toggle(_ value: String, in keyPath: WritableKeyPath<MediaFilterState, [String]>) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if self[keyPath: keyPath].contains(trimmed) {
            self[keyPath: keyPath].removeAll { $0 == trimmed }
        } else {
            self[keyPath: keyPath].append(trimmed)
        }
    }

    mutating func cycleFacet(
        _ value: String,
        include includeKeyPath: WritableKeyPath<MediaFilterState, [String]>,
        exclude excludeKeyPath: WritableKeyPath<MediaFilterState, [String]>
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if self[keyPath: includeKeyPath].contains(trimmed) {
            self[keyPath: includeKeyPath].removeAll { $0 == trimmed }
            self[keyPath: excludeKeyPath].append(trimmed)
        } else if self[keyPath: excludeKeyPath].contains(trimmed) {
            self[keyPath: excludeKeyPath].removeAll { $0 == trimmed }
        } else {
            self[keyPath: includeKeyPath].append(trimmed)
        }
    }

    private static func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func string(_ decimal: Decimal) -> String {
        NSDecimalNumber(decimal: decimal).stringValue
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func append(_ name: String, _ value: String?, to items: inout [URLQueryItem]) {
        guard let value, !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    private func appendTrimmed(_ name: String, _ value: String, to items: inout [URLQueryItem]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: trimmed))
    }
}

struct FilterChoice: Decodable, Hashable, Identifiable {
    let value: String
    let label: String

    var id: String { value }
}

struct MediaFilterOptionsResponse: Decodable, Equatable {
    let sorts: [FilterChoice]
    let genres: [FilterChoice]
    let languages: [FilterChoice]
    let years: [Int]

    static let empty = MediaFilterOptionsResponse(sorts: [], genres: [], languages: [], years: [])
}
