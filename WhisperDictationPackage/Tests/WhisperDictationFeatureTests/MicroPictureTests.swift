import Foundation
import Testing
@testable import WhisperDictationFeature

struct MicroPictureTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let builder = MicroPictureBuilder()

    @Test(arguments: [
        (ClaudeSessionState.working, 0x304FFE),
        (ClaudeSessionState.unread, 0x00FF4C),
        (ClaudeSessionState.idle, 0xFFFFFF),
        (ClaudeSessionState.awaitingApproval, 0xFF6D00),
        (ClaudeSessionState.awaitingResponse, 0xFF6D00),
        (ClaudeSessionState.error, 0xFF0033)
    ])
    func sessionStateMapsToCodexColor(state: ClaudeSessionState, expectedColor: Int) {
        #expect(MicroPalette.color(for: state) == expectedColor)
    }

    @Test(arguments: [
        ("idle", ClaudeSessionState.idle),
        ("working", .working),
        ("unread", .unread),
        ("awaiting-approval", .awaitingApproval),
        ("awaiting-response", .awaitingResponse),
        ("error", .error)
    ])
    func hookStateNameDecodesToSessionState(name: String, expectedState: ClaudeSessionState) throws {
        let json = Data("{\"state\":\"\(name)\",\"cwd\":\"/w\",\"updatedAt\":\"2026-11-03T10:00:00Z\"}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ClaudeSessionFile.self, from: json).state == expectedState)
    }

    @Test func emptySlotsAreOff() {
        #expect(picture(.empty, voice: .idle).slots == MicroPicture.allOff.slots)
    }

    @Test func selectedSlotBreathsInItsColorDuringTheHighlight() {
        let result = pictureAfter(3.9, board: selectedBoard(.unread))
        #expect(result.slots[0] == breathing(0x00FF4C))
    }

    @Test func selectedSlotGoesBackToSolidAfterFourSeconds() {
        let result = pictureAfter(4, board: selectedBoard(.unread))
        #expect(result.slots[0] == solid(0x00FF4C))
    }

    @Test func slotThatIsNotSelectedStaysSolid() {
        let board = ClaudeSlotBoard(
            slots: [slot(.idle), slot(.error), nil, nil, nil, nil],
            selectedSlot: 0,
            selectionChangedAt: Self.base,
            followedFocusID: nil
        )
        #expect(picture(board, voice: .idle).slots[1] == solid(0xFF0033))
    }

    @Test func recordingUsesTheGreenSnakingRing() {
        #expect(picture(.empty, voice: .recording).ambient == snaking(0x2E8B57))
    }

    @Test func transcribingAndInsertingUseTheWhiteSnakingRing() {
        #expect(picture(.empty, voice: .processing).ambient == snaking(0xFFFFFF))
    }

    @Test func justCompletedUsesASolidWhiteRing() {
        #expect(picture(.empty, voice: .completed).ambient == solid(0xFFFFFF))
    }

    @Test func dictationRingOverridesTheWorkingSessionRing() {
        let result = picture(selectedBoard(.working), voice: .recording)
        #expect(result.ambient == snaking(0x2E8B57))
    }

    @Test func selectedWorkingSessionSnakesInItsColor() {
        let result = picture(selectedBoard(.working), voice: .idle)
        #expect(result.ambient == snaking(0x304FFE))
    }

    @Test func selectedSessionThatIsNotWorkingLeavesTheRingOff() {
        let result = picture(selectedBoard(.awaitingApproval), voice: .idle)
        #expect(result.ambient == .off)
    }

    @Test func keysAreAlwaysOff() {
        let result = picture(selectedBoard(.working), voice: .recording)
        #expect(result.keys == .off)
    }

    private func picture(_ board: ClaudeSlotBoard, voice: MicroVoiceLight) -> MicroPicture {
        builder.picture(
            board: board,
            voice: voice,
            now: Self.base
        )
    }

    private func pictureAfter(_ seconds: Double, board: ClaudeSlotBoard) -> MicroPicture {
        builder.picture(
            board: board,
            voice: .idle,
            now: Self.base.addingTimeInterval(seconds)
        )
    }

    private func solid(_ color: Int) -> MicroLightSetting {
        MicroLightSetting(
            effect: .solid,
            color: color,
            brightness: 1,
            speed: 0
        )
    }

    private func breathing(_ color: Int) -> MicroLightSetting {
        MicroLightSetting(
            effect: .breath,
            color: color,
            brightness: 1,
            speed: 0.4
        )
    }

    private func snaking(_ color: Int) -> MicroLightSetting {
        MicroLightSetting(
            effect: .snake,
            color: color,
            brightness: 1,
            speed: 0.4
        )
    }

    private func selectedBoard(_ state: ClaudeSessionState) -> ClaudeSlotBoard {
        ClaudeSlotBoard(
            slots: [slot(state), nil, nil, nil, nil, nil],
            selectedSlot: 0,
            selectionChangedAt: Self.base,
            followedFocusID: nil
        )
    }

    private func slot(_ state: ClaudeSessionState) -> ClaudeSlot {
        ClaudeSlot(
            record: ClaudeSessionRecord(
                sessionID: "s-\(state.rawValue)",
                state: state,
                cwd: "/work",
                updatedAt: Self.base
            ),
            isAcknowledged: false
        )
    }
}
