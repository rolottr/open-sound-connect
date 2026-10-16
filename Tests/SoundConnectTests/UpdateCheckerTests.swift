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

    @Test func releaseUsesTagVersionAndThisMacsArchive() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/rolottr/open-sound-connect/releases/tag/v1.2.0",
         "draft": false, "prerelease": false, "assets": [
          {"name": "Sound-Connect-macos-arm64.zip", "browser_download_url": "https://example.com/arm64.zip"},
          {"name": "Sound-Connect-macos-arm64.zip.sha256", "browser_download_url": "https://example.com/arm64.sha256"},
          {"name": "Sound-Connect-macos-x86_64.zip", "browser_download_url": "https://example.com/x86_64.zip"}]}
        """
        let release = try UpdateChecker.release(from: Data(json.utf8), assetName: "Sound-Connect-macos-x86_64.zip")
        #expect(release.version == "1.2.0")
        #expect(release.downloadURL == URL(string: "https://example.com/x86_64.zip"))
        #expect(release.notesURL.lastPathComponent == "v1.2.0")
    }

    @Test func missingArchiveFallsBackAndPrereleasesAreRejected() throws {
        let noAssets = #"{"tag_name": "1.3.0", "html_url": "https://example.com/r", "draft": false, "prerelease": false, "assets": []}"#
        let release = try UpdateChecker.release(from: Data(noAssets.utf8))
        #expect(release.version == "1.3.0")
        #expect(release.downloadURL == nil)

        let prerelease = #"{"tag_name": "v2.0.0", "html_url": "https://example.com/r", "draft": false, "prerelease": true, "assets": []}"#
        #expect(throws: (any Error).self) { try UpdateChecker.release(from: Data(prerelease.utf8)) }
    }
}
