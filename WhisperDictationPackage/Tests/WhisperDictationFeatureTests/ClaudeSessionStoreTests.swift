import Foundation
import Testing
@testable import WhisperDictationFeature

struct ClaudeSessionStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let oneHour: TimeInterval = 3_600
    private static let overADay: TimeInterval = 86_401

    @Test(arguments: [
        ("", ClaudeSessionHost.claudeDesktop),
        (",\"host\":\"claude-desktop\"", .claudeDesktop),
        (",\"host\":\"t3-code\",\"threadID\":\"thread-1\",\"environmentID\":\"env-1\"", .t3Code),
        (",\"host\":\"unknown\"", nil),
        (",\"host\":null", nil),
        (",\"state\":\"unknown\"", nil)
    ])
    func sessionHostDecoding(metadata: String, expectedHost: ClaudeSessionHost?) throws {
        let sessions = try SessionDirectory()
        defer { sessions.remove() }
        let state = metadata.contains("state") ? "" : "\"state\":\"working\","
        try sessions.writeRaw(
            "{\(state)\"cwd\":\"/work\",\"updatedAt\":\"\(Self.now.ISO8601Format())\"\(metadata)}",
            named: "session.json"
        )
        let expected = expectedHost.map {
            ClaudeSessionRecord(
                sessionID: "session",
                state: .working,
                cwd: "/work",
                updatedAt: Self.now,
                host: $0,
                threadID: $0 == .t3Code ? "thread-1" : nil,
                environmentID: $0 == .t3Code ? "env-1" : nil
            )
        }
        #expect(sessions.records().first == expected)
    }

    @Test(arguments: [
        ("claude-desktop", "ignored-thread", ClaudeSessionHost.claudeDesktop, nil),
        ("t3-code", "Thread_1.2-3", .t3Code, "Thread_1.2-3"),
        ("t3-code", "invalid\"thread", .t3Code, nil),
        ("t3-code", "", .t3Code, nil),
        ("terminal", "thread-1", nil, nil),
        ("", "thread-1", nil, nil)
    ])
    func hookRecordsOnlySupportedHosts(
        entrypoint: String,
        thread: String,
        expectedHost: ClaudeSessionHost?,
        expectedThread: String?
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "claude-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let t3Data = home.appending(path: ".t3/userdata")
        try FileManager.default.createDirectory(at: t3Data, withIntermediateDirectories: true)
        try Data("env-1".utf8).write(to: t3Data.appending(path: "environment-id"))
        let hook = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "integrations/claude-code/claude-micro-hook.sh")
        let cwd = "/work/quote\"/slash\\/line\nend"
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [hook.path, "working"]
        process.environment = [
            "HOME": home.path,
            "CLAUDE_CODE_ENTRYPOINT": entrypoint,
            "T3CODE_THREAD_ID": thread
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": "session-1", "cwd": cwd])
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let directory = home.appending(path: "Library/Application Support/Whisper Dictation/claude-sessions")
        let records = ClaudeSessionStore(directory: directory).records(now: Date())
        let expected = expectedHost.map {
            ClaudeSessionRecord(
                sessionID: "session-1",
                state: .working,
                cwd: "/work/quote\"/slash\\/lineend",
                updatedAt: records.first?.updatedAt ?? .distantPast,
                host: $0,
                threadID: expectedThread,
                environmentID: expectedThread == nil ? nil : "env-1"
            )
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let expectedFiles = expectedHost == nil ? [] : ["session-1.json"]
        let expectedOutput = Data()
        #expect(
            process.terminationStatus == 0
                && output.fileHandleForReading.readDataToEndOfFile() == expectedOutput
                && records == expected.map { [$0] } ?? []
                && files == expectedFiles
        )
    }

    @Test func filesOlderThanTwentyFourHoursAreDropped() throws {
        let sessions = try SessionDirectory()
        defer { sessions.remove() }
        try sessions.write("fresh", ageSeconds: Self.oneHour)
        try sessions.write("stale", ageSeconds: Self.overADay)
        #expect(sessions.records().map { $0.sessionID } == ["fresh"])
    }

    @Test func staleFilesAreRemovedFromDisk() throws {
        let sessions = try SessionDirectory()
        defer { sessions.remove() }
        try sessions.write("stale", ageSeconds: Self.overADay)
        _ = sessions.records()
        #expect(sessions.fileNames().isEmpty)
    }

    @Test func sessionIDComesFromTheFileName() throws {
        let sessions = try SessionDirectory()
        defer { sessions.remove() }
        try sessions.write("8f2c-41", ageSeconds: 0)
        #expect(sessions.records().first?.sessionID == "8f2c-41")
    }

    @Test func unreadableFilesAreSkipped() throws {
        let sessions = try SessionDirectory()
        defer { sessions.remove() }
        try sessions.writeRaw("not json", named: "broken.json")
        try sessions.write("ok", ageSeconds: 0)
        #expect(sessions.records().map { $0.sessionID } == ["ok"])
    }

    @Test func inputDiagnosticKeepsOnlyTheLastFiftyLines() {
        let input = MicroInput.key(
            key: "AG01",
            act: 1,
            agent: nil
        )
        let log = (0..<60).reduce(MicroInputDiagnosticLog(lines: [])) { log, _ in
            log.appending(input, at: Self.now)
        }
        #expect(log.lines.count == 50)
    }

    @Test func inputDiagnosticLineNamesKeyActionAndAgent() {
        let input = MicroInput.key(
            key: "AG02",
            act: 1,
            agent: 3
        )
        let log = MicroInputDiagnosticLog(lines: []).appending(input, at: Self.now)
        #expect(log.lines == ["\(Self.now.ISO8601Format()) hid key=AG02 act=1 agent=3"])
    }

    @Test func inputDiagnosticKeepsActionLinesBesideKeyLines() {
        let input = MicroInput.key(
            key: "ACT09",
            act: 1,
            agent: nil
        )
        let log = MicroInputDiagnosticLog(lines: [])
            .appending(input, at: Self.now)
            .appending(action: "ACT09 opened claude://code/new", at: Self.now)
        let expected = [
            "\(Self.now.ISO8601Format()) hid key=ACT09 act=1 agent=-",
            "\(Self.now.ISO8601Format()) action ACT09 opened claude://code/new"
        ]
        #expect(log.lines == expected)
    }

    private struct SessionDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "claude-session-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }

        func write(_ id: String, ageSeconds: TimeInterval) throws {
            let updatedAt = ClaudeSessionStoreTests.now.addingTimeInterval(-ageSeconds)
            try writeRaw(
                "{\"state\":\"idle\",\"cwd\":\"/work\",\"updatedAt\":\"\(updatedAt.ISO8601Format())\"}",
                named: "\(id).json"
            )
        }

        func writeRaw(_ text: String, named name: String) throws {
            try Data(text.utf8).write(to: url.appending(path: name))
        }

        func records() -> [ClaudeSessionRecord] {
            ClaudeSessionStore(directory: url).records(now: ClaudeSessionStoreTests.now)
        }

        func fileNames() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
