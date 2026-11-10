import Carbon
import Foundation
import Testing
@testable import WhisperDictationFeature

struct HotkeySmokeTests {
    @Test
    func downRepeatDownUpUpEmitsOnePressedAndOneReleased() {
        var filter = PushToTalkEdgeFilter()
        let events = [
            filter.receiveKeyDown(),
            filter.receiveKeyDown(),
            filter.receiveKeyDown(),
            filter.receiveKeyUp(),
            filter.receiveKeyUp(),
        ].compactMap { $0 }

        #expect(events == [.pressed, .released])
    }

    @Test
    func pushToTalkChordRequiresLowConflictInput() {
        let commonShortcut = HotkeyChord(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey)
        )
        let customChord = HotkeyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey)
        )
        let extendedFunctionKey = HotkeyChord(
            keyCode: UInt32(kVK_F18),
            modifiers: 0
        )

        #expect(commonShortcut.validationMessage != nil)
        #expect(customChord.validationMessage == nil)
        #expect(customChord.title == "⌃⌥K")
        #expect(extendedFunctionKey.validationMessage == nil)
        #expect(extendedFunctionKey.title == "F18")
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["HOTKEY_SYSTEM_SMOKE"] == "1",
            "Run scripts/smoke.sh to exercise real Carbon registration."
        )
    )
    @MainActor
    func carbonCanRegisterAndUnregisterAUniqueChord() throws {
        let source = CarbonHotkeySource()
        let chord = HotkeyChord(
            keyCode: UInt32(kVK_F18),
            modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey)
        )

        try source.register(chord: chord) { _ in }
        source.unregister()
    }
}
