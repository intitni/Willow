import Foundation

package struct ThirdPartyLicense: Decodable, Identifiable, Sendable {
    package let id: String
    package let name: String
    package let version: String
    package let license: String
    package let source: URL
    package let text: String
}

package actor ThirdPartyLicenseCatalog {
    package init() {}
    package func load() throws -> [ThirdPartyLicense] {
        struct Document: Decodable { let entries: [ThirdPartyLicense] }
        guard let url = Bundle.module.url(forResource: "ThirdPartyLicenses", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)).entries
    }
}
