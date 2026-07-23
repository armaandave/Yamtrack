import Foundation

struct EmptyResponse: Codable, Equatable {}

struct PagedResponse<T: Decodable>: Decodable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [T]

    init(count: Int, next: String?, previous: String?, results: [T]) {
        self.count = count
        self.next = next
        self.previous = previous
        self.results = results
    }
}

struct MediaSearchResponse: Decodable, Equatable {
    let results: [MediaSummary]
    let unavailableMediaTypes: [String]

    init(results: [MediaSummary], unavailableMediaTypes: [String] = []) {
        self.results = results
        self.unavailableMediaTypes = unavailableMediaTypes
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case unavailableMediaTypes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([MediaSummary].self, forKey: .results)
        unavailableMediaTypes = try container.decodeIfPresent([String].self, forKey: .unavailableMediaTypes) ?? []
    }
}

struct MetaResponse: Decodable {
    let version: String
    let mediaTypes: [String]
    let enabledMediaTypes: [String]?
    let sources: [String: [String]]
    let statusChoices: [String]
    let sourceChoices: [String]
    let dateFormats: [PreferenceChoice]?
    let timeFormats: [PreferenceChoice]?
    let weekStartDays: [PreferenceChoice]?
    let quickWatchDates: [PreferenceChoice]?

    var settingsOptions: SettingsOptions? {
        guard let dateFormats, let timeFormats, let weekStartDays, let quickWatchDates else {
            return nil
        }
        return SettingsOptions(
            dateFormats: dateFormats,
            timeFormats: timeFormats,
            weekStartDays: weekStartDays,
            quickWatchDates: quickWatchDates
        )
    }
}

enum APIConstants {
    static let allMedia = "all"
    static let fallbackMediaTypes = ["movie", "tv", "anime", "manga", "game", "book", "comic", "music", "boardgame"]
    static let statusChoices = ["Completed", "In progress", "Planning", "Paused", "Dropped"]
    static let visibilityChoices = ["public", "followers", "private"]
}
