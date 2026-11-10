import Foundation
import Testing
@testable import WhisperDictationFeature

struct ClaudeSlotBoardTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let laterBy: TimeInterval = 60
    private static let pressedAfter: TimeInterval = 7
    private let assigner = ClaudeSlotAssigner()

    @Test func mixedHostsShareSlotsAndLighting() {
        let desktop = working("desktop", at: 1)
        let t3 = ClaudeSessionRecord(
            sessionID: "t3",
            state: .working,
            cwd: "/work/t3",
            updatedAt: Self.base.addingTimeInterval(2),
            host: .t3Code,
            threadID: "thread-1"
        )
        let mixed = seated([desktop, t3])
        let desktopOnly = seated([desktop, working("t3", at: 2)])
        let builder = MicroPictureBuilder()
        let expected = builder.picture(board: desktopOnly, voice: .idle, now: Self.base)
        #expect(
            ids(mixed) == ["desktop", "t3", nil, nil, nil, nil]
                && mixed.selectedSlot == 1
                && builder.picture(board: mixed, voice: .idle, now: Self.base) == expected
        )
    }

    @Test func newSessionTakesTheLowestFreeSlot() {
        let board = seated([idle("a", at: 1), idle("b", at: 2)])
        let expected: [String?] = ["a", "b", nil, nil, nil, nil]
        #expect(ids(board) == expected)
    }

    @Test func sessionKeepsItsSlotWhenAnEarlierSessionEnds() {
        let first = seated([idle("a", at: 1), idle("b", at: 2)])
        let board = apply([idle("b", at: 2)], to: first)
        let expected: [String?] = [nil, "b", nil, nil, nil, nil]
        #expect(ids(board) == expected)
    }

    @Test func endedSessionFreesItsSlotForTheNextNewSession() {
        let first = seated([idle("a", at: 1), idle("b", at: 2)])
        let ended = apply([idle("b", at: 2)], to: first)
        let board = apply([idle("b", at: 2), idle("c", at: 3)], to: ended)
        let expected: [String?] = ["c", "b", nil, nil, nil, nil]
        #expect(ids(board) == expected)
    }

    @Test func fullBoardEvictsTheLeastRecentlyUpdatedIdleOrUnreadSession() {
        let full = seated([
            working("s0", at: 10),
            idle("s1", at: 20),
            unread("s2", at: 15),
            working("s3", at: 30),
            failed("s4", at: 5),
            awaiting("s5", at: 1)
        ])
        let board = apply(records(of: full) + [idle("new", at: 100)], to: full)
        let expected: [String?] = ["s0", "s1", "new", "s3", "s4", "s5"]
        #expect(ids(board) == expected)
    }

    @Test func fullBoardOfBusySessionsLeavesTheNewSessionWaiting() {
        let full = seated((0..<6).map { working("s\($0)", at: Double($0)) })
        let board = apply(records(of: full) + [idle("new", at: 100)], to: full)
        #expect(ids(board) == ids(full))
    }

    @Test func launchWithEightSessionsSeatsTheSixMostRecentlyUpdated() {
        let board = apply((1...8).map { idle("s\($0)", at: Double($0)) }, to: .empty)
        let expected: [String?] = ["s8", "s7", "s6", "s5", "s4", "s3"]
        #expect(ids(board) == expected)
    }

    @Test func sessionThatStartsWorkingBecomesSelected() {
        let first = seated([idle("a", at: 1), idle("b", at: 2)])
        let board = apply([idle("a", at: 1), working("b", at: 5)], to: first)
        #expect(board.selectedSlot == 1)
    }

    @Test func laterWorkingTransitionMovesTheSelection() {
        let first = apply(
            [working("a", at: 5), idle("b", at: 2)],
            to: seated([idle("a", at: 1), idle("b", at: 2)])
        )
        let board = applyLater([working("a", at: 5), working("b", at: 9)], to: first)
        #expect(board.selectedSlot == 1)
    }

    @Test func repeatedWorkingUpdateKeepsTheSelectionTimestamp() {
        let first = apply([working("a", at: 5)], to: seated([idle("a", at: 1)]))
        let board = applyLater([working("a", at: 9)], to: first)
        #expect(board.selectionChangedAt == Self.base)
    }

    @Test func endedSelectedSessionClearsTheSelection() {
        let first = apply([working("a", at: 5)], to: seated([idle("a", at: 1)]))
        #expect(applyLater([], to: first).selectedSlot == nil)
    }

    @Test func pressingASlotSelectsItAtThePressTime() {
        let board = press(1, on: seated([idle("a", at: 1), idle("b", at: 2)]))
        #expect(board.selectedSlot == 1)
        #expect(board.selectionChangedAt == Self.base.addingTimeInterval(Self.pressedAfter))
    }

    @Test func pressingAnUnreadSlotMarksItIdle() {
        let board = press(0, on: seated([unread("a", at: 1)]))
        #expect(board.slots[0]?.state == .idle)
    }

    @Test func newUnreadUpdateAfterAPressIsUnreadAgain() {
        let pressed = press(0, on: seated([unread("a", at: 1)]))
        let board = apply([unread("a", at: 9)], to: pressed)
        #expect(board.slots[0]?.state == .unread)
    }

    @Test func pressingAnEmptySlotChangesNothing() {
        let first = seated([idle("a", at: 1)])
        #expect(press(4, on: first) == first)
    }

    @Test func focusedSessionOnTheBoardBecomesSelected() {
        let first = seated([idle("a", at: 1), idle("b", at: 2)])
        let board = applyFocused([idle("a", at: 1), idle("b", at: 2)], focus: "b", to: first)
        #expect(board.selectedSlot == 1)
    }

    @Test func focusMovingToAnotherSessionMovesTheSelection() {
        let records = [idle("a", at: 1), idle("b", at: 2)]
        let first = applyFocused(records, focus: "a", to: seated(records))
        let board = applyFocusedLater(records, focus: "b", to: first)
        #expect(board.selectedSlot == 1)
        #expect(board.selectionChangedAt == Self.base.addingTimeInterval(Self.laterBy))
    }

    @Test func unchangedFocusKeepsTheSelectionTimestamp() {
        let records = [idle("a", at: 1), idle("b", at: 2)]
        let first = applyFocused(records, focus: "b", to: seated(records))
        let board = applyFocusedLater(records, focus: "b", to: first)
        #expect(board.selectionChangedAt == Self.base)
    }

    @Test func workingTransitionDoesNotMoveSelectionFromAFocusedSession() {
        let first = applyFocused(
            [idle("a", at: 1), idle("b", at: 2)],
            focus: "a",
            to: seated([idle("a", at: 1), idle("b", at: 2)])
        )
        let board = applyFocusedLater([idle("a", at: 1), working("b", at: 9)], focus: "a", to: first)
        #expect(board.selectedSlot == 0)
    }

    @Test func focusOnASessionThatIsNotOnTheBoardFallsBackToTheWorkingTransition() {
        let first = seated([idle("a", at: 1), idle("b", at: 2)])
        let board = applyFocusedLater([idle("a", at: 1), working("b", at: 9)], focus: "elsewhere", to: first)
        #expect(board.selectedSlot == 1)
    }

    @Test func keyPressSelectionStaysWhileTheFocusIsUnchanged() {
        let records = [idle("a", at: 1), idle("b", at: 2)]
        let focused = applyFocused(records, focus: "a", to: seated(records))
        let pressed = press(1, on: focused)
        #expect(applyFocusedLater(records, focus: "a", to: pressed).selectedSlot == 1)
    }

    @Test func focusFollowingAKeyPressKeepsTheSelectionTimestamp() {
        let records = [idle("a", at: 1), idle("b", at: 2)]
        let pressed = press(1, on: applyFocused(records, focus: "a", to: seated(records)))
        let board = applyFocusedLater(records, focus: "b", to: pressed)
        #expect(board.selectionChangedAt == Self.base.addingTimeInterval(Self.pressedAfter))
    }

    @Test func focusReturningToABoardSessionSelectsItAgain() {
        let records = [idle("a", at: 1), idle("b", at: 2)]
        let focused = applyFocused(records, focus: "a", to: seated(records))
        let pressed = press(1, on: focused)
        let away = applyFocusedLater(records, focus: "elsewhere", to: pressed)
        #expect(applyFocusedLater(records, focus: "a", to: away).selectedSlot == 0)
    }

    @Test func focusKnownBeforeTheSessionArrivesSelectsItOnArrival() {
        let waiting = applyFocused([], focus: "a", to: .empty)
        let board = applyFocusedLater([idle("a", at: 1)], focus: "a", to: waiting)
        #expect(board.selectedSlot == 0)
    }

    @Test func endedSelectedSessionLeavesTheFocusedSessionSelected() {
        let records = [idle("a", at: 1), idle("b", at: 2)]
        let focused = applyFocused(records, focus: "a", to: seated(records))
        let pressed = press(1, on: focused)
        let board = applyFocusedLater([idle("a", at: 1)], focus: "a", to: pressed)
        #expect(board.selectedSlot == 0)
    }

    private func seated(_ records: [ClaudeSessionRecord]) -> ClaudeSlotBoard {
        records.indices.reduce(ClaudeSlotBoard.empty) { board, index in
            apply(Array(records[...index]), to: board)
        }
    }

    private func apply(
        _ records: [ClaudeSessionRecord],
        to board: ClaudeSlotBoard
    ) -> ClaudeSlotBoard {
        assigner.applying(
            records,
            to: board,
            focusedSessionID: nil,
            now: Self.base
        )
    }

    private func applyLater(
        _ records: [ClaudeSessionRecord],
        to board: ClaudeSlotBoard
    ) -> ClaudeSlotBoard {
        assigner.applying(
            records,
            to: board,
            focusedSessionID: nil,
            now: Self.base.addingTimeInterval(Self.laterBy)
        )
    }

    private func applyFocused(
        _ records: [ClaudeSessionRecord],
        focus: String?,
        to board: ClaudeSlotBoard
    ) -> ClaudeSlotBoard {
        assigner.applying(
            records,
            to: board,
            focusedSessionID: focus,
            now: Self.base
        )
    }

    private func applyFocusedLater(
        _ records: [ClaudeSessionRecord],
        focus: String?,
        to board: ClaudeSlotBoard
    ) -> ClaudeSlotBoard {
        assigner.applying(
            records,
            to: board,
            focusedSessionID: focus,
            now: Self.base.addingTimeInterval(Self.laterBy)
        )
    }

    private func press(_ slot: Int, on board: ClaudeSlotBoard) -> ClaudeSlotBoard {
        assigner.pressing(
            slot: slot,
            on: board,
            now: Self.base.addingTimeInterval(Self.pressedAfter)
        )
    }

    private func records(of board: ClaudeSlotBoard) -> [ClaudeSessionRecord] {
        board.slots.compactMap { $0?.record }
    }

    private func ids(_ board: ClaudeSlotBoard) -> [String?] {
        board.slots.map { $0?.record.sessionID }
    }

    private func idle(_ id: String, at seconds: Double) -> ClaudeSessionRecord {
        record(
            id,
            state: .idle,
            seconds: seconds
        )
    }

    private func working(_ id: String, at seconds: Double) -> ClaudeSessionRecord {
        record(
            id,
            state: .working,
            seconds: seconds
        )
    }

    private func unread(_ id: String, at seconds: Double) -> ClaudeSessionRecord {
        record(
            id,
            state: .unread,
            seconds: seconds
        )
    }

    private func failed(_ id: String, at seconds: Double) -> ClaudeSessionRecord {
        record(
            id,
            state: .error,
            seconds: seconds
        )
    }

    private func awaiting(_ id: String, at seconds: Double) -> ClaudeSessionRecord {
        record(
            id,
            state: .awaitingApproval,
            seconds: seconds
        )
    }

    private func record(
        _ id: String,
        state: ClaudeSessionState,
        seconds: Double
    ) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            sessionID: id,
            state: state,
            cwd: "/work/\(id)",
            updatedAt: Self.base.addingTimeInterval(seconds)
        )
    }
}
