import Foundation
import Testing
@testable import WhisperDictationFeature

struct ClaudeDesktopSessionStoreTests {
    @Test func localIDComesFromTheFileWithTheMatchingCLISessionID() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000, organisation: "org-a")
        try sessions.write(localID: "local_two", cliSessionID: "cli-2", focusedAt: 2_000, organisation: "org-b")
        #expect(sessions.scan().localID(for: "cli-2") == "local_two")
    }

    @Test func sessionFromAnotherAccountIsFound() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000, account: "acct-b")
        #expect(sessions.scan().localID(for: "cli-1") == "local_one")
    }

    @Test func unknownCLISessionHasNoLocalID() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        #expect(sessions.scan().localID(for: "cli-9") == nil)
    }

    @Test func malformedFileIsSkipped() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.writeRaw("not json", named: "local_broken.json")
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        #expect(sessions.scan().localID(for: "cli-1") == "local_one")
    }

    @Test func fileWithoutACLISessionIDIsSkipped() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.writeRaw("{\"sessionId\":\"local_one\"}", named: "local_one.json")
        #expect(sessions.scan().entries.compactMap { $0.session }.isEmpty)
    }

    @Test(arguments: ["../escape", "local_", "abc-123", "local_a b", "local_abc\n", "local_ab/cd"])
    func sessionIDOutsideTheClaudeFormatIsSkipped(sessionID: String) throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(
            localID: sessionID,
            cliSessionID: "cli-1",
            focusedAt: 1_000,
            named: "local_file.json"
        )
        #expect(sessions.scan().localID(for: "cli-1") == nil)
    }

    @Test func fileWithoutLastFocusedAtStillResolvesItsID() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: nil)
        #expect(sessions.scan().localID(for: "cli-1") == "local_one")
    }

    @Test func lastFocusedAtOfTheWrongTypeStillResolvesItsID() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.writeRaw(
            "{\"sessionId\":\"local_one\",\"cliSessionId\":\"cli-1\",\"lastFocusedAt\":\"yesterday\"}",
            named: "local_one.json"
        )
        #expect(sessions.scan().localID(for: "cli-1") == "local_one")
    }

    @Test func focusedSessionHasTheHighestLastFocusedAt() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 3_000)
        try sessions.write(localID: "local_two", cliSessionID: "cli-2", focusedAt: 9_000, organisation: "org-b")
        try sessions.write(localID: "local_three", cliSessionID: "cli-3", focusedAt: 5_000)
        #expect(sessions.scan().focusedCLISessionID == "cli-2")
    }

    @Test func sessionsNeverFocusedAreNotFocused() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: nil)
        try sessions.write(localID: "local_two", cliSessionID: "cli-2", focusedAt: 1_000)
        #expect(sessions.scan().focusedCLISessionID == "cli-2")
    }

    @Test func noSessionFilesMeansNoFocusedSession() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        #expect(sessions.scan().focusedCLISessionID == nil)
    }

    @Test func missingRootGivesAnEmptyIndex() {
        let store = ClaudeDesktopSessionStore(
            root: FileManager.default.temporaryDirectory
                .appending(path: "claude-desktop-missing-\(UUID().uuidString)")
        )
        #expect(store.scan(reusing: .empty) == .empty)
    }

    @Test func lastFocusedAtIsReadInMilliseconds() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_792_508_447_011)
        let expected = Date(timeIntervalSince1970: 1_792_508_447.011)
        #expect(sessions.scan().entries.first?.session?.lastFocusedAt == expected)
    }

    @Test func filesAtOtherDepthsAreIgnored() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.writeAtRoot(localID: "local_root", cliSessionID: "cli-root")
        try sessions.writeAtAccount(localID: "local_account", cliSessionID: "cli-account")
        try sessions.writeBelowOrganisation(localID: "local_deep", cliSessionID: "cli-deep")
        #expect(sessions.scan().entries.isEmpty)
    }

    @Test func filesThatAreNotSessionFilesAreIgnored() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.writeRaw(
            "{\"sessionId\":\"local_one\",\"cliSessionId\":\"cli-1\"}",
            named: "notes.json"
        )
        #expect(sessions.scan().entries.isEmpty)
    }

    @Test func aMissRescansAndFindsAFileWrittenAfterTheCache() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        let cached = sessions.scan()
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        let resolution = sessions.store.resolving("cli-1", in: cached)
        #expect(resolution.localID == "local_one")
        #expect(resolution.index.localID(for: "cli-1") == "local_one")
    }

    @Test func aMissThatStaysAMissReturnsNoLocalID() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        #expect(sessions.store.resolving("cli-9", in: sessions.scan()).localID == nil)
    }

    @Test func aHitDoesNotRescan() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        let cached = sessions.scan()
        try sessions.writeRaw("{\"sessionId\":\"local_two\",\"cliSessionId\":\"cli-2\"}", named: "local_two.json")
        #expect(sessions.store.resolving("cli-1", in: cached).index == cached)
    }

    @Test func unchangedFileIsNotReadAgain() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        try sessions.touch("local_one", at: modified)
        let cached = sessions.scan()
        try sessions.write(localID: "local_one", cliSessionID: "cli-changed", focusedAt: 1_000)
        try sessions.touch("local_one", at: modified)
        #expect(sessions.store.scan(reusing: cached).localID(for: "cli-1") == "local_one")
    }

    @Test func changedFileIsReadAgain() throws {
        let sessions = try DesktopSessions()
        defer { sessions.remove() }
        try sessions.write(localID: "local_one", cliSessionID: "cli-1", focusedAt: 1_000)
        try sessions.touch("local_one", at: Date(timeIntervalSince1970: 1_700_000_000))
        let cached = sessions.scan()
        try sessions.write(localID: "local_one", cliSessionID: "cli-changed", focusedAt: 1_000)
        try sessions.touch("local_one", at: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(sessions.store.scan(reusing: cached).localID(for: "cli-changed") == "local_one")
    }

    private struct DesktopSessions {
        let root: URL
        let store: ClaudeDesktopSessionStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "claude-desktop-\(UUID().uuidString)")
            store = ClaudeDesktopSessionStore(root: root)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func write(
            localID: String,
            cliSessionID: String,
            focusedAt: Double?,
            account: String = "acct-a",
            organisation: String = "org-a",
            named name: String? = nil
        ) throws {
            let directory = try directory(account, organisation)
            try writeJSON(
                localID: localID,
                cliSessionID: cliSessionID,
                focusedAt: focusedAt,
                to: directory.appending(path: name ?? "\(localID).json")
            )
        }

        func writeRaw(
            _ text: String,
            named name: String
        ) throws {
            try Data(text.utf8).write(to: directory("acct-a", "org-a").appending(path: name))
        }

        func writeAtRoot(localID: String, cliSessionID: String) throws {
            try writeJSON(
                localID: localID,
                cliSessionID: cliSessionID,
                focusedAt: 1_000,
                to: root.appending(path: "\(localID).json")
            )
        }

        func writeAtAccount(localID: String, cliSessionID: String) throws {
            try writeJSON(
                localID: localID,
                cliSessionID: cliSessionID,
                focusedAt: 1_000,
                to: directory("acct-a").appending(path: "\(localID).json")
            )
        }

        func writeBelowOrganisation(localID: String, cliSessionID: String) throws {
            try writeJSON(
                localID: localID,
                cliSessionID: cliSessionID,
                focusedAt: 1_000,
                to: directory("acct-a", "org-a", "archive").appending(path: "\(localID).json")
            )
        }

        func touch(_ localID: String, at date: Date) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: directory("acct-a", "org-a")
                    .appending(path: "\(localID).json").path
            )
        }

        func scan() -> ClaudeDesktopIndex {
            store.scan(reusing: .empty)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func directory(_ components: String...) throws -> URL {
            let url = components.reduce(root) { $0.appending(path: $1) }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        }

        private func writeJSON(
            localID: String,
            cliSessionID: String,
            focusedAt: Double?,
            to url: URL
        ) throws {
            let fields: [String: Any?] = [
                "sessionId": localID,
                "cliSessionId": cliSessionID,
                "lastFocusedAt": focusedAt
            ]
            let object = fields.compactMapValues { $0 }
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
    }
}
