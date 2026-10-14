import AppKit
import Testing
@testable import SoundConnect

@MainActor
struct PlaybackTests {
    @Test func volumeRoundingRemainsDistinctFromExactConfirmation() {
        let state = DeviceState()
        state.nowPlaying.volume = 16
        #expect(DeviceChange.volume(17).isReflected(in: state) == false)
        #expect(DeviceChange.volume(17).adjustment(in: state) != nil)
        #expect(DeviceChange.volume(16).isReflected(in: state) == true)
        #expect(DeviceChange.volume(16).adjustment(in: state) == nil)
        #expect(DeviceChange.volume(20).adjustment(in: state) == nil)
        #expect(DeviceChange.upscaling(true).adjustment(in: state) == nil)
    }

    @Test func muteAndMaximumMustMatchExactly() {
        let state = DeviceState()
        state.nowPlaying.volume = 1
        #expect(DeviceChange.volume(0).adjustment(in: state) == nil)
        #expect(DeviceChange.volume(0).isReflected(in: state) == false)
        state.nowPlaying.volume = 29
        #expect(DeviceChange.volume(30).adjustment(in: state) == nil)
        state.nowPlaying.volume = nil
        #expect(DeviceChange.volume(17).adjustment(in: state) == nil)
    }

    @Test func trackRepliesCannotConfirmVolume() {
        let matcher = MDRLink.Matcher(.dataMdr, 0xA7, 0x01, detail: 0x20)
        #expect(matcher.matches(MDRFrame(type: .dataMdr, sequence: 0, payload: [0xA7, 0x01, 0x20, 16])))
        #expect(!matcher.matches(MDRFrame(type: .dataMdr, sequence: 0, payload: [0xA7, 0x01, 0x00, 0x02, 0])))
        #expect(!matcher.matches(MDRFrame(type: .dataMdr, sequence: 0, payload: [0xA7, 0x01])))
        #expect(!matcher.matches(MDRFrame(type: .dataMdrNo2, sequence: 0, payload: [0xA7, 0x01, 0x20, 16])))
    }

    @Test func metadataReplacesThePreviousTrackAndClearsOnExit() throws {
        let player = SystemNowPlaying()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.purple.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let artwork = try #require(image.tiffRepresentation).base64EncodedString()
        func event(_ payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload])
        }
        player.consume(try event(["bundleIdentifier": "test.player", "title": "테스트 🎵",
                                 "artist": "Test Artist", "album": "Test", "playing": true, "artworkData": artwork]))
        #expect(player.item?.title == "테스트 🎵")
        #expect(player.item?.playing == true)
        #expect(player.artwork != nil)
        player.consume(try event(["bundleIdentifier": "another.player", "title": "Next track", "playing": false]))
        #expect(player.item?.title == "Next track")
        #expect(player.item?.playing == false)
        #expect(player.item?.artist == nil)
        #expect(player.artwork == nil)
        player.consume(try event([:]))
        #expect(player.item == nil)
        #expect(player.artwork == nil)
    }

    @Test func missingOrInvalidMediaFallsBackWithoutCrashing() {
        let player = SystemNowPlaying()
        for json in ["null", "not JSON", "{}", "{\"type\":\"data\",\"payload\":null}",
                     "{\"type\":\"data\",\"payload\":{\"title\":\"incomplete\"}}"] {
            player.consume(Data(json.utf8))
            #expect(player.item == nil)
        }
    }
}
