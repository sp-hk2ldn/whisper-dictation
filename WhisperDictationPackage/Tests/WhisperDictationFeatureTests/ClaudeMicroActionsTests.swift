import Foundation
import Testing
@testable import WhisperDictationFeature

@MainActor
struct ClaudeMicroActionsTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let claude = FrontmostApplication(
        bundleIdentifier: "com.anthropic.claudefordesktop",
        processIdentifier: 4242
    )
    private static let terminal = FrontmostApplication(
        bundleIdentifier: "com.apple.Terminal",
        processIdentifier: 99
    )

    @Test(arguments: [
        (true, Optional("thread-1")),
        (true, nil),
        (false, Optional("thread-1"))
    ])
    func t3SlotActivatesOnlyT3Code(installed: Bool, threadID: String?) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "claude-t3-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "acct/org")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"sessionId\":\"local_a\",\"cliSessionId\":\"t3\"}".utf8)
            .write(to: directory.appending(path: "local_a.json"))
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        app.stubbedT3ActivationResult = installed
        let slot = ClaudeSlot(
            record: ClaudeSessionRecord(
                sessionID: "t3",
                state: .unread,
                cwd: "/work",
                updatedAt: Self.base,
                host: .t3Code,
                threadID: threadID
            ),
            isAcknowledged: false
        )
        let outcome = ClaudeMicroActions(
            app: app,
            desktopStore: ClaudeDesktopSessionStore(root: root)
        ).perform(.slot(1), on: board([nil, slot]), host: .t3Code, index: .empty)
        let thread = threadID.map { " (thread \($0))" } ?? ""
        let expected = ClaudeMicroOutcome(
            log: installed
                ? "AG01 activated T3 Code for slot 1\(thread)"
                : "AG01 ignored: T3 Code is not installed or could not be opened",
            openedSlot: installed ? 1 : nil,
            index: .empty
        )
        #expect(
            outcome == expected
                && app.t3ActivationCount == 1
                && app.openedURLs.isEmpty
                && app.postedKeystrokes.isEmpty
        )
    }

    @Test func newTaskOpensTheNewTaskLink() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = perform(.action(.newTask), board: board([]), index: .empty, app: app)
        #expect(app.openedURLs == [URL(string: "claude://code/new")!])
        #expect(outcome.log == "ACT09 opened claude://code/new")
    }

    @Test func waitingOpensTheWaitingLinkWithoutASession() {
        let app = FakeClaudeApp(frontmost: Self.terminal, postSucceeds: true)
        let outcome = perform(.action(.waiting), board: board([]), index: .empty, app: app)
        #expect(app.openedURLs == [URL(string: "claude://code/needs-input")!])
        #expect(outcome.log == "ACT12 opened claude://code/needs-input")
    }

    @Test func actionKeysThatOpenALinkDoNotMarkASlotPressed() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = perform(.action(.newTask), board: board([]), index: .empty, app: app)
        #expect(outcome.openedSlot == nil)
    }

    @Test func slotKeyOpensContinueWithTheClaudeSessionID() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = perform(
            .slot(1),
            board: board([nil, session("cli-a", .working, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.openedURLs == [URL(string: "claude://code/continue?session=local_a")!])
        #expect(outcome.log == "AG01 opened claude://code/continue?session=local_a")
        #expect(outcome.openedSlot == 1)
    }

    @Test func slotKeyOnASessionThatNeedsInputOpensNeedsInputWithTheClaudeSessionID() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        _ = perform(
            .slot(0),
            board: board([session("cli-a", .awaitingResponse, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.openedURLs == [URL(string: "claude://code/needs-input?session=local_a")!])
    }

    @Test func slotKeyWithoutAMatchOpensTheLastSession() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = perform(
            .slot(0),
            board: board([session("cli-a", .working, at: 1)]),
            index: .empty,
            app: app
        )
        #expect(app.openedURLs == [URL(string: "claude://code/continue?session=last")!])
        #expect(outcome.log == "AG00 opened claude://code/continue?session=last (no Claude session match)")
    }

    @Test func slotKeyOnASessionThatNeedsInputWithoutAMatchOpensNeedsInput() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        _ = perform(
            .slot(0),
            board: board([session("cli-a", .awaitingApproval, at: 1)]),
            index: .empty,
            app: app
        )
        #expect(app.openedURLs == [URL(string: "claude://code/needs-input")!])
    }

    @Test func slotKeyOnAnEmptySlotDoesNothing() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = perform(.slot(3), board: board([]), index: .empty, app: app)
        #expect(app.openedURLs.isEmpty)
        #expect(outcome.log == "AG03 ignored: slot is empty")
        #expect(outcome.openedSlot == nil)
    }

    @Test func approveSendsReturnToClaudeWhenTheFocusedSessionAwaitsApproval() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: true)
        let outcome = perform(
            .action(.approve),
            board: board([session("cli-a", .awaitingApproval, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.postedKeystrokes == [PostedKeystroke(keystroke: .returnKey, processIdentifier: 4242)])
        #expect(app.openedURLs.isEmpty)
        #expect(outcome.log == "ACT07 sent Return to Claude")
    }

    @Test func rejectSendsEscapeToClaudeWhenTheFocusedSessionAwaitsApproval() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: true)
        let outcome = perform(
            .action(.reject),
            board: board([session("cli-a", .awaitingApproval, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.postedKeystrokes == [PostedKeystroke(keystroke: .escape, processIdentifier: 4242)])
        #expect(outcome.log == "ACT08 sent Escape to Claude")
    }

    @Test func stopSendsEscapeToClaudeWhenTheFocusedSessionIsWorking() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: true)
        let outcome = perform(
            .action(.stop),
            board: board([session("cli-a", .working, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.postedKeystrokes == [PostedKeystroke(keystroke: .escape, processIdentifier: 4242)])
        #expect(outcome.log == "ACT06 sent Escape to Claude")
    }

    @Test func aKeystrokeThatCouldNotBePostedIsLoggedAsIgnored() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: false)
        let outcome = perform(
            .action(.approve),
            board: board([session("cli-a", .awaitingApproval, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(outcome.log == "ACT07 ignored: could not post Return to Claude")
    }

    @Test func approveOpensTheWaitingSessionWhenClaudeIsNotFrontmost() {
        let app = FakeClaudeApp(frontmost: Self.terminal, postSucceeds: true)
        let outcome = perform(
            .action(.approve),
            board: board([session("cli-a", .awaitingApproval, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.openedURLs == [URL(string: "claude://code/needs-input?session=local_a")!])
        #expect(app.postedKeystrokes.isEmpty)
        #expect(outcome.log == "ACT07 opened claude://code/needs-input?session=local_a, no key sent: Claude is not frontmost")
        #expect(outcome.openedSlot == 0)
    }

    @Test func approveNeverPostsAKeyWhenTheFocusedSessionIsIdle() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: true)
        let outcome = perform(
            .action(.approve),
            board: board([session("cli-a", .idle, at: 1), session("cli-b", .awaitingApproval, at: 2)]),
            index: index([
                desktop("local_a", "cli-a", focusedAt: 9),
                desktop("local_b", "cli-b", focusedAt: 1)
            ]),
            app: app
        )
        #expect(app.postedKeystrokes.isEmpty)
        #expect(app.openedURLs == [URL(string: "claude://code/needs-input?session=local_b")!])
        #expect(outcome.log == "ACT07 opened claude://code/needs-input?session=local_b, no key sent: focused session is not awaiting-approval")
    }

    @Test func approveWithNothingAwaitingDoesNothing() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: true)
        let outcome = perform(
            .action(.approve),
            board: board([session("cli-a", .idle, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(app.postedKeystrokes.isEmpty)
        #expect(app.openedURLs.isEmpty)
        #expect(outcome.log == "ACT07 ignored: no session is awaiting-approval")
    }

    @Test func stopWithNothingWorkingDoesNothing() {
        let app = FakeClaudeApp(frontmost: Self.claude, postSucceeds: true)
        let outcome = perform(
            .action(.stop),
            board: board([session("cli-a", .idle, at: 1)]),
            index: index([desktop("local_a", "cli-a", focusedAt: 1)]),
            app: app
        )
        #expect(outcome.log == "ACT06 ignored: no session is working")
    }

    @Test func aMissRescansTheDesktopDirectoryAndReturnsTheRefreshedIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "claude-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "acct/org")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"sessionId\":\"local_a\",\"cliSessionId\":\"cli-a\",\"lastFocusedAt\":5}".utf8)
            .write(to: directory.appending(path: "local_a.json"))
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = ClaudeMicroActions(
            app: app,
            desktopStore: ClaudeDesktopSessionStore(root: root)
        ).perform(
            .slot(0),
            on: board([session("cli-a", .working, at: 1)]),
            host: .claudeDesktop,
            index: .empty
        )
        #expect(app.openedURLs == [URL(string: "claude://code/continue?session=local_a")!])
        #expect(outcome.index.localID(for: "cli-a") == "local_a")
    }

    @Test func t3SlotWithBothIDsOpensItsThreadLink() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        let outcome = perform(
            .slot(0),
            board: board([t3Session("s", .unread, at: 1, environment: "env-1")]),
            host: .t3Code,
            index: .empty,
            app: app
        )
        #expect(
            app.openedURLs == [URL(string: "t3code://threads/env-1/thread-s")!]
                && app.t3ActivationCount == 0
                && outcome.log == "AG00 opened t3code://threads/env-1/thread-s"
                && outcome.openedSlot == 0
        )
    }

    @Test func newTaskOnT3OpensANewT3Thread() {
        let app = FakeClaudeApp(frontmost: nil, postSucceeds: true)
        _ = perform(.action(.newTask), board: board([]), host: .t3Code, index: .empty, app: app)
        #expect(app.openedURLs == [URL(string: "t3code://new")!])
    }

    @Test func approveOnT3OpensTheThreadWithoutSendingAKey() {
        let app = FakeClaudeApp(frontmost: Self.terminal, postSucceeds: true)
        let outcome = perform(
            .action(.approve),
            board: board([t3Session("s", .awaitingApproval, at: 1, environment: "env-1")]),
            host: .t3Code,
            index: .empty,
            app: app
        )
        #expect(
            app.openedURLs == [URL(string: "t3code://threads/env-1/thread-s")!]
                && app.postedKeystrokes.isEmpty
                && outcome.log.hasSuffix("no key sent: T3 Code has no shortcut for this key")
        )
    }

    private func t3Session(
        _ id: String,
        _ state: ClaudeSessionState,
        at seconds: Double,
        environment: String?
    ) -> ClaudeSlot {
        ClaudeSlot(
            record: ClaudeSessionRecord(
                sessionID: id,
                state: state,
                cwd: "/work/\(id)",
                updatedAt: Self.base.addingTimeInterval(seconds),
                host: .t3Code,
                threadID: "thread-\(id)",
                environmentID: environment
            ),
            isAcknowledged: false
        )
    }

    private func perform(
        _ press: MicroPress,
        board: ClaudeSlotBoard,
        host: ClaudeSessionHost = .claudeDesktop,
        index: ClaudeDesktopIndex,
        app: FakeClaudeApp
    ) -> ClaudeMicroOutcome {
        ClaudeMicroActions(
            app: app,
            desktopStore: ClaudeDesktopSessionStore(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "claude-actions-missing-\(UUID().uuidString)")
            )
        ).perform(
            press,
            on: board,
            host: host,
            index: index
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

    private func index(_ sessions: [ClaudeDesktopSession]) -> ClaudeDesktopIndex {
        ClaudeDesktopIndex(
            entries: sessions.map {
                ClaudeDesktopFileEntry(
                    path: "/\($0.localID).json",
                    modifiedAt: Self.base,
                    session: $0
                )
            }
        )
    }

    private func desktop(
        _ localID: String,
        _ cliSessionID: String,
        focusedAt seconds: Double
    ) -> ClaudeDesktopSession {
        ClaudeDesktopSession(
            localID: localID,
            cliSessionID: cliSessionID,
            lastFocusedAt: Self.base.addingTimeInterval(seconds)
        )
    }
}

struct PostedKeystroke: Equatable {
    let keystroke: ClaudeKeystroke
    let processIdentifier: pid_t
}

@MainActor
final class FakeClaudeApp: ClaudeAppControlling {
    private let stubbedFrontmost: FrontmostApplication?
    private let stubbedPostResult: Bool
    var stubbedT3ActivationResult = true
    private(set) var t3ActivationCount = 0
    private(set) var openedURLs: [URL] = []
    private(set) var postedKeystrokes: [PostedKeystroke] = []

    init(frontmost: FrontmostApplication?, postSucceeds: Bool) {
        stubbedFrontmost = frontmost
        stubbedPostResult = postSucceeds
    }

    func frontmostApplication() -> FrontmostApplication? {
        stubbedFrontmost
    }

    func open(_ url: URL) {
        openedURLs.append(url)
    }

    func activateT3Code() -> Bool {
        t3ActivationCount += 1
        return stubbedT3ActivationResult
    }

    func post(_ keystroke: ClaudeKeystroke, toProcess processIdentifier: pid_t) -> Bool {
        postedKeystrokes.append(
            PostedKeystroke(
                keystroke: keystroke,
                processIdentifier: processIdentifier
            )
        )
        return stubbedPostResult
    }
}
