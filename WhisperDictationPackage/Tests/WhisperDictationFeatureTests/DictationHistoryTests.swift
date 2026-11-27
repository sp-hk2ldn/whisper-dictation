import Foundation
import Testing
@testable import WhisperDictationFeature

@MainActor
struct DictationHistoryTests {
    private static let recordedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let corruptData = Data("invalid JSON".utf8)

    @Test
    func newestEntryAppearsFirst() {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        let history = makeHistory(at: fileURL)
        let firstID = UUID()
        let secondID = UUID()
        let expectedIDs = [secondID, firstID]

        history.add(id: firstID, text: "First")
        history.add(id: secondID, text: "Second")

        #expect(history.entries.map { $0.id } == expectedIDs)
    }

    @Test
    func theTwentyFirstEntryEvictsTheOldest() {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        let history = makeHistory(at: fileURL)
        let ids = (1...21).map { _ in UUID() }
        let expectedIDs = Array(ids.dropFirst().reversed())

        for id in ids {
            history.add(id: id, text: "Dictation")
        }

        #expect(history.entries.map { $0.id } == expectedIDs)
    }

    @Test
    func historySurvivesReload() {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        let history = makeHistory(at: fileURL)
        let expectedEntry = DictationHistory.Entry(
            id: UUID(),
            text: "  Keep the original text.\n",
            date: Self.recordedDate
        )

        history.add(id: expectedEntry.id, text: expectedEntry.text)
        let reloaded = makeHistory(at: fileURL)

        #expect(reloaded.entries == [expectedEntry])
    }

    @Test
    func aCorruptFileLoadsAsEmpty() throws {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        try writeCorruptHistory(at: fileURL)
        let expectedEntries: [DictationHistory.Entry] = []

        let history = makeHistory(at: fileURL)

        #expect(history.entries == expectedEntries)
    }

    @Test
    func theNextWriteStartsNewHistoryAfterCorruption() throws {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        try writeCorruptHistory(at: fileURL)
        let history = makeHistory(at: fileURL)
        let expectedID = UUID()

        history.add(id: expectedID, text: "New dictation")
        let reloaded = makeHistory(at: fileURL)

        #expect(reloaded.entries.map { $0.id } == [expectedID])
    }

    @Test
    func theNextWritePreservesCorruptHistoryInAnArchive() throws {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        try writeCorruptHistory(at: fileURL)
        let history = makeHistory(at: fileURL)
        let archive = fileURL.deletingLastPathComponent().appending(
            path: "history-unreadable-1700000000.json",
            directoryHint: .notDirectory
        )
        let expectedArchive = Self.corruptData

        history.add(id: UUID(), text: "New dictation")
        let archived = try Data(contentsOf: archive)

        #expect(archived == expectedArchive)
    }

    @Test
    func theFileIsOnlyReadableAndWritableByItsOwner() throws {
        let fileURL = temporaryHistoryURL()
        defer { removeTemporaryHistory(at: fileURL) }
        let history = makeHistory(at: fileURL)
        let expectedPermissions = 0o600

        history.add(id: UUID(), text: "First")
        history.add(id: UUID(), text: "Second")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        #expect(attributes[.posixPermissions] as? Int == expectedPermissions)
    }

    private func makeHistory(at fileURL: URL) -> DictationHistory {
        DictationHistory(fileURL: fileURL, now: { Self.recordedDate })
    }

    private func writeCorruptHistory(at fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.corruptData.write(to: fileURL)
    }

    private func removeTemporaryHistory(at fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "history.json", directoryHint: .notDirectory)
    }
}
