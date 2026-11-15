import Foundation
import Testing
@testable import Core

private actor ReleaseSource {
    var requests = 0
    var release: WillowRelease?
    var fails = false

    init(release: WillowRelease?) {
        self.release = release
    }

    func fetch() throws -> WillowRelease? {
        requests += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return release
    }

    func setFailure() { fails = true }
    func setRelease(_ release: WillowRelease?) {
        fails = false
        self.release = release
    }
}

@Suite @MainActor
struct UpdateModelTests {
    private let newer = WillowRelease(
        tagName: "version/1.10.0",
        notes: "Release notes",
        url: URL(string: "https://github.com/intitni/Willow/releases/tag/version/1.10.0")!
    )

    @Test
    func startupChecksOnceAcrossWindows() async {
        let source = ReleaseSource(release: newer)
        let model = UpdateModel(version: "1.9.9", fetchRelease: { try await source.fetch() })

        let first = model.startInitialCheck()
        let second = model.startInitialCheck()
        await first.value
        await second.value
        await model.startInitialCheck().value

        #expect(await source.requests == 1)
        #expect(model.isUpdateAvailable == true)
        #expect(model.latestRelease?.notes == "Release notes")
    }

    @Test
    func failedRetryKeepsUpdateAndSuccessfulRetryReplacesIt() async {
        let source = ReleaseSource(release: newer)
        let model = UpdateModel(version: "1.9.9", fetchRelease: { try await source.fetch() })
        await model.checkForUpdates()

        await source.setFailure()
        await model.checkForUpdates()
        #expect(model.updateCheckFailed)
        #expect(model.isUpdateAvailable == true)

        await source.setRelease(nil)
        await model.checkForUpdates()
        #expect(!model.updateCheckFailed)
        #expect(model.noPublishedRelease)
        #expect(model.isUpdateAvailable == nil)
    }

    @Test
    func onlyNewerVersionsShowAnUpdate() async {
        let source = ReleaseSource(release: newer)
        let current = UpdateModel(version: "1.10.0", fetchRelease: { try await source.fetch() })
        let ahead = UpdateModel(version: "2.0.0", fetchRelease: { try await source.fetch() })
        await current.checkForUpdates()
        await ahead.checkForUpdates()
        #expect(current.isUpdateAvailable == false)
        #expect(ahead.isUpdateAvailable == false)
    }

    @Test
    func missingManifestFailsWhilePublishedNullMeansNoRelease() throws {
        let url = URL(string: "https://raw.githubusercontent.com/intitni/Willow/refs/heads/release-note/release.json")!
        let missing = try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
        let published = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

        #expect(throws: URLError(.badServerResponse)) {
            try UpdateModel.decodeReleaseManifest(Data(), response: missing)
        }
        #expect(try UpdateModel.decodeReleaseManifest(Data("null".utf8), response: published) == nil)
    }
}
