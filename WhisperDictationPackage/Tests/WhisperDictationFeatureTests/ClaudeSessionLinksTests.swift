import Foundation
import Testing
@testable import WhisperDictationFeature

struct ClaudeSessionLinksTests {
    private let links = ClaudeSessionLinks()

    @Test(arguments: [ClaudeSessionState.awaitingApproval, .awaitingResponse])
    func aSlotThatNeedsInputOpensNeedsInputWithTheClaudeSessionID(state: ClaudeSessionState) {
        let url = links.url(for: slot(state), localID: "local_abc-123")
        #expect(url == URL(string: "claude://code/needs-input?session=local_abc-123"))
    }

    @Test(arguments: [ClaudeSessionState.awaitingApproval, .awaitingResponse])
    func aSlotThatNeedsInputWithoutAMatchOpensNeedsInputWithoutASession(state: ClaudeSessionState) {
        #expect(links.url(for: slot(state), localID: nil) == URL(string: "claude://code/needs-input"))
    }

    @Test(arguments: [ClaudeSessionState.idle, .working, .unread, .error])
    func anyOtherSlotOpensContinueWithTheClaudeSessionID(state: ClaudeSessionState) {
        let url = links.url(for: slot(state), localID: "local_abc-123")
        #expect(url == URL(string: "claude://code/continue?session=local_abc-123"))
    }

    @Test(arguments: [ClaudeSessionState.idle, .working, .unread, .error])
    func anyOtherSlotWithoutAMatchOpensTheLastSession(state: ClaudeSessionState) {
        #expect(links.url(for: slot(state), localID: nil) == URL(string: "claude://code/continue?session=last"))
    }

    @Test func anAcknowledgedUnreadSlotOpensContinue() {
        let acknowledged = ClaudeSlot(record: record(.unread), isAcknowledged: true)
        let url = links.url(for: acknowledged, localID: "local_abc-123")
        #expect(url == URL(string: "claude://code/continue?session=local_abc-123"))
    }

    @Test func newTaskOpensTheNewTaskLink() {
        #expect(ClaudeSessionLinks.newTask == URL(string: "claude://code/new"))
    }

    @Test func waitingOpensNeedsInputWithoutASession() {
        #expect(ClaudeSessionLinks.waiting == URL(string: "claude://code/needs-input"))
    }

    private func slot(_ state: ClaudeSessionState) -> ClaudeSlot {
        ClaudeSlot(record: record(state), isAcknowledged: false)
    }

    private func record(_ state: ClaudeSessionState) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            sessionID: "abc-123",
            state: state,
            cwd: "/work",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
