import XCTest
@testable import XIsland

final class UpdateManagerURLTests: XCTestCase {
    @MainActor
    func testBuildsReleasePayloadFromLatestRedirectURL() throws {
        let checkedAt = ISO8601DateFormatter().date(from: "2026-04-15T06:42:03Z")!
        let payload = try UpdateManager.releaseDataFromLatestRedirectURL(
            URL(string: "https://github.com/Meteorkid/XIsland/releases/tag/v1.2.8")!,
            checkedAt: checkedAt
        )
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: payload)

        XCTAssertEqual(release.tagName, "v1.2.8")
        XCTAssertEqual(release.htmlURL, URL(string: "https://github.com/Meteorkid/XIsland/releases/tag/v1.2.8"))
        XCTAssertEqual(release.publishedAt, checkedAt)
        XCTAssertEqual(
            release.dmgURL,
            URL(string: "https://github.com/Meteorkid/XIsland/releases/download/v1.2.8/XIsland.dmg")
        )
    }

    @MainActor
    func testRejectsUnexpectedLatestRedirectURL() {
        XCTAssertThrowsError(
            try UpdateManager.releaseDataFromLatestRedirectURL(
                URL(string: "https://github.com/Meteorkid/XIsland/releases")!,
                checkedAt: Date()
            )
        )
        XCTAssertThrowsError(
            try UpdateManager.releaseDataFromLatestRedirectURL(
                URL(string: "https://github.com/wrong/XIsland/releases/tag/v1.0.0")!,
                checkedAt: Date()
            )
        )
    }

    @MainActor
    func testBuildsReleasePayloadFromLatestRedirectURLWithQueryString() throws {
        let checkedAt = ISO8601DateFormatter().date(from: "2026-04-15T07:30:00Z")!
        let payload = try UpdateManager.releaseDataFromLatestRedirectURL(
            URL(string: "https://github.com/Meteorkid/XIsland/releases/tag/v1.2.9?from=latest")!,
            checkedAt: checkedAt
        )
        let release = try UpdateManager.githubReleaseDecoder.decode(UpdateManager.ReleaseInfo.self, from: payload)

        XCTAssertEqual(release.tagName, "v1.2.9")
        XCTAssertEqual(
            release.dmgURL,
            URL(string: "https://github.com/Meteorkid/XIsland/releases/download/v1.2.9/XIsland.dmg")
        )
    }
}
