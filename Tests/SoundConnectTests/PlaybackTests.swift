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
}
