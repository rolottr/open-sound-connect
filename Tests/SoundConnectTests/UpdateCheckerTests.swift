import Foundation
import Testing
@testable import SoundConnect

@MainActor
struct UpdateCheckerTests {
    @Test func versionsCompareNumericallyByComponent() {
        #expect(UpdateChecker.isVersion("1.2.0", newerThan: "1.1.0"))
        #expect(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.2"))
        #expect(UpdateChecker.isVersion("2", newerThan: "1.99"))
        #expect(UpdateChecker.isVersion("1.1.1", newerThan: "1.1"))
        #expect(!UpdateChecker.isVersion("1.1.0", newerThan: "1.1.0"))
        #expect(!UpdateChecker.isVersion("1.1", newerThan: "1.1.0"))
        #expect(!UpdateChecker.isVersion("1.0.9", newerThan: "1.1.0"))
    }

    @Test func releaseUsesTagVersionAndReleasePage() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/rolottr/open-sound-connect/releases/tag/v1.2.0",
         "draft": false, "prerelease": false, "assets": [
          {"name": "Sound-Connect-macos-arm64.zip", "browser_download_url": "https://example.com/arm64.zip"}]}
        """
        let release = try UpdateChecker.release(from: Data(json.utf8))
        #expect(release.version == "1.2.0")
        #expect(release.pageURL == URL(string: "https://github.com/rolottr/open-sound-connect/releases/tag/v1.2.0"))

        let untagged = #"{"tag_name": "1.3.0", "html_url": "https://example.com/r", "draft": false, "prerelease": false}"#
        #expect(try UpdateChecker.release(from: Data(untagged.utf8)).version == "1.3.0")
    }

    @Test func prereleasesAndDraftsAreRejected() {
        let prerelease = #"{"tag_name": "v2.0.0", "html_url": "https://example.com/r", "draft": false, "prerelease": true}"#
        #expect(throws: (any Error).self) { try UpdateChecker.release(from: Data(prerelease.utf8)) }
        let draft = #"{"tag_name": "v2.0.0", "html_url": "https://example.com/r", "draft": true, "prerelease": false}"#
        #expect(throws: (any Error).self) { try UpdateChecker.release(from: Data(draft.utf8)) }
    }
}
