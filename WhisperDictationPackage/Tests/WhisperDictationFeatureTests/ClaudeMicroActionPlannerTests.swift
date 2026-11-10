import Foundation
import Testing
@testable import WhisperDictationFeature

struct ClaudeMicroActionPlannerTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let claude = FrontmostApplication(
        bundleIdentifier: "com.anthropic.claudefordesktop",
        processIdentifier: 4242
    )
    private static let terminal = FrontmostApplication(
        bundleIdentifier: "com.apple.Terminal",
        processIdentifier: 99
    )
    static let responses: [(MicroActionKey, ClaudeKeystroke)] = [
        (.approve, .returnKey),
        (.reject, .escape)
    ]
    static let statesThatAreNotAwaitingApproval: [ClaudeSessionState] = [
        .idle,
        .working,
        .unread,
        .awaitingResponse,
        .error
    ]
    static let statesThatAreNotWorking: [ClaudeSessionState] = [
        .idle,
        .unread,
        .awaitingApproval,
        .awaitingResponse,
        .error
    ]
    static let anyFrontmost: [FrontmostApplication?] = [claude, terminal, nil]
    static let notClaudeFrontmost: [FrontmostApplication?] = [terminal, nil]
    private let planner = ClaudeMicroActionPlanner()

    @Test(arguments: [MicroActionKey.approve, .reject, .stop])
    func responseKeysOnlyTargetDesktopSessions(action: MicroActionKey) {
        let state = action == .stop ? ClaudeSessionState.working : .awaitingApproval
        let t3 = ClaudeSlot(
            record: ClaudeSessionRecord(
                sessionID: "t3",
                state: state,
                cwd: "/work/t3",
                updatedAt: Self.base.addingTimeInterval(100),
                host: .t3Code,
                threadID: "thread-1"
            ),
            isAcknowledged: false
        )
        let desktop = session("desktop", state, at: 1)
        let expected: [ClaudeMicroPlan] = [
            .ignore(.noSession(in: state)),
            .redirect(ClaudeSlotTarget(index: 1, slot: desktop), because: .claudeNotFrontmost),
            .redirect(ClaudeSlotTarget(index: 1, slot: desktop), because: .focusedSessionNotOnBoard)
        ]
        let actual = [
            plan(.action(action), board: board([t3]), focused: "t3", frontmost: Self.claude),
            plan(.action(action), board: board([t3, desktop]), focused: nil, frontmost: Self.terminal),
            plan(.action(action), board: board([t3, desktop]), focused: "t3", frontmost: Self.claude)
        ]
        #expect(actual == expected)
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.anyFrontmost)
    func newTaskAlwaysOpensTheNewTaskLink(frontmost: FrontmostApplication?) {
        let result = plan(.action(.newTask), board: board([]), focused: nil, frontmost: frontmost)
        #expect(result == .openNewTask)
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.anyFrontmost)
    func waitingAlwaysOpensTheWaitingLink(frontmost: FrontmostApplication?) {
        let result = plan(.action(.waiting), board: board([]), focused: nil, frontmost: frontmost)
        #expect(result == .openWaiting)
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.responses)
    func approvalKeysSendTheirKeystrokeWhenTheFocusedSessionAwaitsApproval(
        action: MicroActionKey,
        keystroke: ClaudeKeystroke
    ) {
        let result = plan(
            .action(action),
            board: board([session("a", .awaitingApproval, at: 1)]),
            focused: "a",
            frontmost: Self.claude
        )
        #expect(result == .send(keystroke, toProcess: 4242))
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.responses, ClaudeMicroActionPlannerTests.statesThatAreNotAwaitingApproval)
    func approvalKeysNeverSendWhenTheFocusedSessionIsInAnotherState(
        response: (MicroActionKey, ClaudeKeystroke),
        state: ClaudeSessionState
    ) {
        let result = plan(
            .action(response.0),
            board: board([session("a", state, at: 1)]),
            focused: "a",
            frontmost: Self.claude
        )
        #expect(result == .ignore(.noSession(in: .awaitingApproval)))
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.responses, ClaudeMicroActionPlannerTests.statesThatAreNotAwaitingApproval)
    func approvalKeysOpenTheWaitingSlotInsteadWhenTheFocusedSessionIsInAnotherState(
        response: (MicroActionKey, ClaudeKeystroke),
        state: ClaudeSessionState
    ) {
        let waiting = session("b", .awaitingApproval, at: 2)
        let result = plan(
            .action(response.0),
            board: board([session("a", state, at: 1), waiting]),
            focused: "a",
            frontmost: Self.claude
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 1, slot: waiting),
            because: .focusedSessionNotIn(.awaitingApproval)
        )
        #expect(result == expected)
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.notClaudeFrontmost)
    func approvalKeysOpenTheWaitingSlotWhenClaudeIsNotFrontmost(frontmost: FrontmostApplication?) {
        let waiting = session("a", .awaitingApproval, at: 1)
        let result = plan(
            .action(.approve),
            board: board([waiting]),
            focused: "a",
            frontmost: frontmost
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 0, slot: waiting),
            because: .claudeNotFrontmost
        )
        #expect(result == expected)
    }

    @Test func approvalKeysOpenTheWaitingSlotWhenTheFocusedSessionIsNotOnTheBoard() {
        let waiting = session("a", .awaitingApproval, at: 1)
        let result = plan(
            .action(.approve),
            board: board([waiting]),
            focused: "elsewhere",
            frontmost: Self.claude
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 0, slot: waiting),
            because: .focusedSessionNotOnBoard
        )
        #expect(result == expected)
    }

    @Test func approvalKeysOpenTheWaitingSlotWhenNoSessionIsFocused() {
        let waiting = session("a", .awaitingApproval, at: 1)
        let result = plan(
            .action(.approve),
            board: board([waiting]),
            focused: nil,
            frontmost: Self.claude
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 0, slot: waiting),
            because: .focusedSessionNotOnBoard
        )
        #expect(result == expected)
    }

    @Test func approvalRedirectsToTheMostRecentlyUpdatedWaitingSlot() {
        let newer = session("b", .awaitingApproval, at: 9)
        let result = plan(
            .action(.approve),
            board: board([session("a", .awaitingApproval, at: 3), newer, session("c", .awaitingApproval, at: 5)]),
            focused: nil,
            frontmost: Self.terminal
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 1, slot: newer),
            because: .claudeNotFrontmost
        )
        #expect(result == expected)
    }

    @Test func approvalWithNoSessionAwaitingApprovalDoesNothing() {
        let result = plan(
            .action(.approve),
            board: board([session("a", .working, at: 1), nil, session("c", .idle, at: 2)]),
            focused: "a",
            frontmost: Self.claude
        )
        #expect(result == .ignore(.noSession(in: .awaitingApproval)))
    }

    @Test func stopSendsEscapeWhenTheFocusedSessionIsWorking() {
        let result = plan(
            .action(.stop),
            board: board([session("a", .working, at: 1)]),
            focused: "a",
            frontmost: Self.claude
        )
        #expect(result == .send(.escape, toProcess: 4242))
    }

    @Test(arguments: ClaudeMicroActionPlannerTests.statesThatAreNotWorking)
    func stopNeverSendsWhenTheFocusedSessionIsInAnotherState(state: ClaudeSessionState) {
        let result = plan(
            .action(.stop),
            board: board([session("a", state, at: 1)]),
            focused: "a",
            frontmost: Self.claude
        )
        #expect(result == .ignore(.noSession(in: .working)))
    }

    @Test func stopOpensTheWorkingSlotWhenTheFocusedSessionIsIdle() {
        let working = session("b", .working, at: 2)
        let result = plan(
            .action(.stop),
            board: board([session("a", .idle, at: 1), working]),
            focused: "a",
            frontmost: Self.claude
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 1, slot: working),
            because: .focusedSessionNotIn(.working)
        )
        #expect(result == expected)
    }

    @Test func stopOpensTheWorkingSlotWhenClaudeIsNotFrontmost() {
        let working = session("a", .working, at: 1)
        let result = plan(
            .action(.stop),
            board: board([working]),
            focused: "a",
            frontmost: Self.terminal
        )
        let expected = ClaudeMicroPlan.redirect(
            ClaudeSlotTarget(index: 0, slot: working),
            because: .claudeNotFrontmost
        )
        #expect(result == expected)
    }

    @Test func stopNeverEscapesASessionThatIsAwaitingApproval() {
        let result = plan(
            .action(.stop),
            board: board([session("a", .awaitingApproval, at: 1)]),
            focused: "a",
            frontmost: Self.claude
        )
        #expect(result == .ignore(.noSession(in: .working)))
    }

    @Test func anOccupiedSlotKeyOpensItsSlot() {
        let occupied = session("a", .idle, at: 1)
        let result = plan(
            .slot(2),
            board: board([nil, nil, occupied]),
            focused: nil,
            frontmost: nil
        )
        #expect(result == .openSlot(ClaudeSlotTarget(index: 2, slot: occupied)))
    }

    @Test func anEmptySlotKeyDoesNothing() {
        let result = plan(
            .slot(3),
            board: board([session("a", .idle, at: 1)]),
            focused: nil,
            frontmost: nil
        )
        #expect(result == .ignore(.emptySlot))
    }

    @Test func waitingOnT3OpensTheMostRecentThreadThatNeedsInput() {
        let older = t3("old", .awaitingApproval, at: 1)
        let newer = t3("new", .awaitingResponse, at: 2)
        let busy = t3("busy", .working, at: 3)
        let result = plan(
            .action(.waiting), board: board([older, busy, newer]),
            host: .t3Code, focused: nil, frontmost: nil
        )
        #expect(result == .openSlot(ClaudeSlotTarget(index: 2, slot: newer)))
    }

    @Test func waitingOnT3WithNothingWaitingDoesNothing() {
        let result = plan(
            .action(.waiting), board: board([t3("busy", .working, at: 1)]),
            host: .t3Code, focused: nil, frontmost: nil
        )
        #expect(result == .ignore(.nothingWaiting))
    }

    @Test(arguments: [MicroActionKey.approve, .reject, .stop])
    func responseKeysOnT3RedirectToTheThread(action: MicroActionKey) {
        let state = action == .stop ? ClaudeSessionState.working : .awaitingApproval
        let slot = t3("s", state, at: 1)
        let result = plan(
            .action(action), board: board([slot]),
            host: .t3Code, focused: "s", frontmost: Self.claude
        )
        #expect(result == .redirect(ClaudeSlotTarget(index: 0, slot: slot), because: .t3HasNoShortcut))
    }

    private func t3(_ id: String, _ state: ClaudeSessionState, at seconds: Double) -> ClaudeSlot {
        ClaudeSlot(
            record: ClaudeSessionRecord(
                sessionID: id,
                state: state,
                cwd: "/work/\(id)",
                updatedAt: Self.base.addingTimeInterval(seconds),
                host: .t3Code,
                threadID: "thread-\(id)"
            ),
            isAcknowledged: false
        )
    }

    private func plan(
        _ press: MicroPress,
        board: ClaudeSlotBoard,
        host: ClaudeSessionHost = .claudeDesktop,
        focused: String?,
        frontmost: FrontmostApplication?
    ) -> ClaudeMicroPlan {
        planner.plan(
            for: press,
            in: ClaudeMicroContext(
                host: host,
                board: board,
                focusedSessionID: focused,
                frontmost: frontmost
            )
        )
    }

    private func board(_ slots: [ClaudeSlot?]) -> ClaudeSlotBoard {
        let padding: [ClaudeSlot?] = Array(
            repeating: nil,
            count: ClaudeSlotBoard.slotCount - slots.count
        )
        return ClaudeSlotBoard(
            slots: slots + padding,
            selectedSlot: nil,
            selectionChangedAt: nil,
            followedFocusID: nil
        )
    }

    private func session(
        _ id: String,
        _ state: ClaudeSessionState,
        at seconds: Double
    ) -> ClaudeSlot {
        ClaudeSlot(
            record: ClaudeSessionRecord(
                sessionID: id,
                state: state,
                cwd: "/work/\(id)",
                updatedAt: Self.base.addingTimeInterval(seconds)
            ),
            isAcknowledged: false
        )
    }
}

struct MicroPressTests {
    @Test(arguments: [
        ("AG00", MicroPress.slot(0)),
        ("AG05", .slot(5)),
        ("ACT06", .action(.stop)),
        ("ACT07", .action(.approve)),
        ("ACT08", .action(.reject)),
        ("ACT09", .action(.newTask)),
        ("ACT12", .action(.waiting))
    ])
    func aPressedKeyIsRecognised(key: String, expected: MicroPress) {
        #expect(MicroPress(.key(key: key, act: 1, agent: nil)) == expected)
    }

    @Test(arguments: ["AG02", "ACT07", "ACT09", "ACT12"])
    func aReleasedKeyIsNotAPress(key: String) {
        #expect(MicroPress(.key(key: key, act: 0, agent: nil)) == nil)
    }

    @Test(arguments: ["AG02", "ACT07"])
    func aKeyWithoutAnActionIsNotAPress(key: String) {
        #expect(MicroPress(.key(key: key, act: nil, agent: nil)) == nil)
    }

    @Test(arguments: ["ACT11", "ACT10", "AG06", "ACT01"])
    func aKeyThatIsNotMappedIsNotAPress(key: String) {
        #expect(MicroPress(.key(key: key, act: 1, agent: nil)) == nil)
    }

    @Test func aJoystickEventIsNotAPress() {
        #expect(MicroPress(.joystick(angle: 0.5, distance: 1)) == nil)
    }

    @Test func aKeyboardEventIsNotAPress() {
        #expect(MicroPress(.keyboard(usagePage: 7, usage: 0x6D, act: 1)) == nil)
    }
}
