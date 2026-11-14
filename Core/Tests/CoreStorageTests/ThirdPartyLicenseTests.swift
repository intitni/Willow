import CoreStorage
import Testing

struct ThirdPartyLicenseTests {
    @Test func bundledNoticesIncludeCoveredRuntimeAndDependencyLicenses() async throws {
        let entries = try await ThirdPartyLicenseCatalog().load()
        #expect(Set(entries.map(\.id)).count == entries.count)
        let breeze = try #require(entries.first { $0.id == "Breeze" })
        #expect(breeze.license == "MPL-2.0")
        #expect(breeze.source.absoluteString.hasSuffix(breeze.version))
        #expect(breeze.text.contains("Distribution of Executable Form"))
        let runtime = try #require(entries.first { $0.name == "rquickjs_playground" })
        #expect(runtime.text.contains("Copyright (c) 2026 Adam Shaw"))
        #expect(runtime.text.contains("Permission is hereby granted"))
        let quickJS = try #require(entries.first { $0.name == "rquickjs-sys" })
        #expect(quickJS.text.contains("Fabrice Bellard"))
        #expect(quickJS.text.contains("The above copyright notice"))
        #expect(entries.allSatisfy { !$0.text.isEmpty && $0.source.scheme == "https" })
    }
}
