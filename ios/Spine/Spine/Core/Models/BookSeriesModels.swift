import Foundation

struct SeriesRef: Codable, Hashable, Identifiable {
    let source: String
    let id: String
    let mediaType: String

    init(source: String, id: String, mediaType: String = "book") {
        self.source = source
        self.id = id
        self.mediaType = mediaType
    }
}

struct BookSeriesSummary: Codable, Hashable, Identifiable {
    let id: String
    let source: String
    let name: String
    let bookCount: Int
    let posterUrls: [String]

    var ref: SeriesRef {
        SeriesRef(source: source, id: id)
    }
}

struct SeriesDetail: Decodable, Hashable, Identifiable {
    let seriesId: String
    let source: String
    let mediaType: String
    let name: String
    let itemCount: Int
    let items: [MediaSummary]

    var id: String { seriesId }

    var ref: SeriesRef {
        SeriesRef(source: source, id: seriesId, mediaType: mediaType)
    }

    var bookCount: Int { itemCount }
    var books: [MediaSummary] { items }

    private enum CodingKeys: String, CodingKey {
        case seriesId
        case id
        case source
        case mediaType
        case name
        case itemCount
        case items
        case bookCount
        case books
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems = try container.decodeIfPresent([MediaSummary].self, forKey: .items)
            ?? container.decodeIfPresent([MediaSummary].self, forKey: .books)
            ?? []

        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
            ?? container.decode(String.self, forKey: .id)
        source = try container.decode(String.self, forKey: .source)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
            ?? decodedItems.first?.ref.mediaType
            ?? "book"
        name = try container.decode(String.self, forKey: .name)
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
            ?? container.decodeIfPresent(Int.self, forKey: .bookCount)
            ?? decodedItems.count
        items = decodedItems
    }
}
