import Foundation

struct CompanyRef: Codable, Hashable, Identifiable {
    let source: String
    let companyId: String

    var id: String { "\(source):\(companyId)" }

    enum CodingKeys: String, CodingKey {
        case source
        case companyId = "id"
    }
}

struct CompanyDetail: Decodable, Hashable {
    let id: String
    let source: String
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
    let websites: [String]
    let catalogs: CompanyCatalogCounts

    var ref: CompanyRef {
        CompanyRef(source: source, companyId: id)
    }
}

struct CompanyParent: Decodable, Hashable {
    let id: String
    let name: String
}

struct CompanyCatalogCounts: Decodable, Hashable {
    let developed: CompanyCatalogCount
    let published: CompanyCatalogCount
}

struct CompanyCatalogCount: Decodable, Hashable {
    let count: Int
}

enum CompanyCatalogRole: String, CaseIterable, Hashable, Identifiable {
    case developed
    case published

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developed: "Developed"
        case .published: "Published"
        }
    }

    var creditRole: String {
        switch self {
        case .developed: "Developer"
        case .published: "Publisher"
        }
    }

    func count(in detail: CompanyDetail) -> Int {
        switch self {
        case .developed: detail.catalogs.developed.count
        case .published: detail.catalogs.published.count
        }
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
