import Foundation

struct BookSeriesRef: Codable, Hashable, Identifiable {
    let source: String
    let id: String
}

struct BookSeriesSummary: Codable, Hashable, Identifiable {
    let id: String
    let source: String
    let name: String
    let bookCount: Int
    let posterUrls: [String]

    var ref: BookSeriesRef {
        BookSeriesRef(source: source, id: id)
    }
}

struct BookSeriesDetail: Codable, Hashable, Identifiable {
    let id: String
    let source: String
    let name: String
    let bookCount: Int
    let books: [MediaSummary]

    var ref: BookSeriesRef {
        BookSeriesRef(source: source, id: id)
    }
}
