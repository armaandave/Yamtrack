import Foundation

struct CompanyRef: Codable, Hashable, Identifiable {
    let source: String
    let companyId: String

    var id: String { "\(source):\(companyId)" }
    var isAnimeStudio: Bool { source.caseInsensitiveCompare("mal") == .orderedSame }

    enum CodingKeys: String, CodingKey {
        case source
        case companyId = "id"
    }
}

struct CompanyDetail: Decodable, Hashable {
    let id: String
    let source: String
    let mediaType: String?
    let name: String
    let description: String?
    let logoUrl: String?
    let logoWidth: Int?
    let logoHeight: Int?
    let foundedYear: Int?
    let countryCode: Int?
    let status: String?
    let companySize: String?
    let parent: CompanyParent?
    let igdbUrl: String?
    let providerUrl: String?
    let websites: [String]
    let catalogs: CompanyCatalogCounts
    let completion: CompletionProgress?

    init(
        id: String,
        source: String,
        mediaType: String?,
        name: String,
        description: String?,
        logoUrl: String?,
        logoWidth: Int?,
        logoHeight: Int?,
        foundedYear: Int?,
        countryCode: Int?,
        status: String?,
        companySize: String?,
        parent: CompanyParent?,
        igdbUrl: String?,
        providerUrl: String?,
        websites: [String],
        catalogs: CompanyCatalogCounts,
        completion: CompletionProgress? = nil
    ) {
        self.id = id
        self.source = source
        self.mediaType = mediaType
        self.name = name
        self.description = description
        self.logoUrl = logoUrl
        self.logoWidth = logoWidth
        self.logoHeight = logoHeight
        self.foundedYear = foundedYear
        self.countryCode = countryCode
        self.status = status
        self.companySize = companySize
        self.parent = parent
        self.igdbUrl = igdbUrl
        self.providerUrl = providerUrl
        self.websites = websites
        self.catalogs = catalogs
        self.completion = completion
    }

    var ref: CompanyRef {
        CompanyRef(source: source, companyId: id)
    }

    var resolvedMediaType: String {
        mediaType ?? (ref.isAnimeStudio ? "anime" : "game")
    }

    var catalogRoles: [CompanyCatalogRole] {
        if resolvedMediaType == "anime" {
            guard catalogs.studio?.available == true else { return [] }
            return [.studio]
        }
        return [.developed, .published].filter {
            guard let catalog = catalogs.catalog(for: $0), catalog.available else { return false }
            return (catalog.count ?? 0) > 0
        }
    }
}

struct CompanyParent: Decodable, Hashable {
    let id: String
    let name: String
}

struct CompanyCatalogCounts: Decodable, Hashable {
    let developed: CompanyCatalogCount
    let published: CompanyCatalogCount
    let studio: CompanyCatalogCount?

    init(
        developed: CompanyCatalogCount = .unavailable,
        published: CompanyCatalogCount = .unavailable,
        studio: CompanyCatalogCount? = nil
    ) {
        self.developed = developed
        self.published = published
        self.studio = studio
    }

    private enum CodingKeys: String, CodingKey {
        case developed
        case published
        case studio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        developed = try container.decodeIfPresent(CompanyCatalogCount.self, forKey: .developed) ?? .unavailable
        published = try container.decodeIfPresent(CompanyCatalogCount.self, forKey: .published) ?? .unavailable
        studio = try container.decodeIfPresent(CompanyCatalogCount.self, forKey: .studio)
    }

    func catalog(for role: CompanyCatalogRole) -> CompanyCatalogCount? {
        switch role {
        case .developed: developed
        case .published: published
        case .studio: studio
        }
    }
}

struct CompanyCatalogCount: Decodable, Hashable {
    let count: Int?
    let available: Bool
    let completion: CompletionProgress?

    init(
        count: Int?,
        available: Bool = true,
        completion: CompletionProgress? = nil
    ) {
        self.count = count
        self.available = available
        self.completion = completion
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case available
        case completion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
        completion = try container.decodeIfPresent(CompletionProgress.self, forKey: .completion)
    }

    static let unavailable = CompanyCatalogCount(count: 0, available: false)
}

struct CompanyCatalogPage: Decodable {
    let count: Int?
    let next: String?
    let previous: String?
    let results: [MediaSummary]
    let completion: CompletionProgress?

    init(
        count: Int?,
        next: String?,
        previous: String?,
        results: [MediaSummary],
        completion: CompletionProgress? = nil
    ) {
        self.count = count
        self.next = next
        self.previous = previous
        self.results = results
        self.completion = completion
    }
}

enum CompanyCatalogRole: String, CaseIterable, Hashable, Identifiable {
    case developed
    case published
    case studio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developed: "Developed"
        case .published: "Published"
        case .studio: "Studio"
        }
    }

    var creditRole: String {
        switch self {
        case .developed: "Developer"
        case .published: "Publisher"
        case .studio: "Studio"
        }
    }

    var mediaType: String {
        self == .studio ? "anime" : "game"
    }

    var collectionTitle: String {
        self == .studio ? "Anime" : "Games"
    }

    func count(in detail: CompanyDetail) -> Int? {
        detail.catalogs.catalog(for: self)?.count
    }

    func itemNoun(count: Int) -> String {
        if self == .studio {
            return "anime"
        }
        return count == 1 ? "game" : "games"
    }
}

struct MediaCompanyCredit: Hashable, Identifiable {
    let ref: CompanyRef
    let name: String
    let roles: [String]

    var id: String { ref.id }

    init?(json: JSONValue) {
        guard case let .object(value) = json,
              let source = value["source"]?.stringValue,
              let companyId = value["id"]?.stringValue,
              let name = value["name"]?.stringValue,
              !source.isEmpty,
              !companyId.isEmpty,
              !name.isEmpty
        else { return nil }
        self.ref = CompanyRef(source: source, companyId: companyId)
        self.name = name
        self.roles = value["roles"]?.stringArrayValue ?? []
    }

    func hasRole(_ role: CompanyCatalogRole) -> Bool {
        roles.contains(role.creditRole)
    }
}

extension JSONValue {
    var stringArrayValue: [String]? {
        guard case let .array(values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }
}
