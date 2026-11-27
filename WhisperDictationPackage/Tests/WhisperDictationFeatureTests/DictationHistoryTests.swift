//
//  DictationHistoryTests.swift
//  WhisperDictation
//
//  Created by Stephen Parker on 27/11/2026.
//

import Foundation
import Testing
@testable import WhisperDictationFeature

@MainActor
struct DictationHistoryTests {
    private static let recordedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func newestEntryAppearsFirst() {
        let history = makeHistory(at: temporaryHistoryURL())
        let firstID = UUID()
        let secondID = UUID()
        let expectedIDs = [secondID, firstID]

        history.add(id: firstID, text: "First")
        history.add(id: secondID, text: "Second")

        #expect(history.entries.map { $0.id } == expectedIDs)
    }

    @Test
    func theTwentyFirstEntryEvictsTheOldest() {
        let history = makeHistory(at: temporaryHistoryURL())
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
        let fileURL = try corruptHistoryURL()
        let expectedEntries: [DictationHistory.Entry] = []

        let history = makeHistory(at: fileURL)

        #expect(history.entries == expectedEntries)
    }

    @Test
    func theNextWriteReplacesCorruptHistory() throws {
        let fileURL = try corruptHistoryURL()
        let history = makeHistory(at: fileURL)
        let expectedID = UUID()

        history.add(id: expectedID, text: "New dictation")
        let reloaded = makeHistory(at: fileURL)

        #expect(reloaded.entries.map { $0.id } == [expectedID])
    }

    @Test
    func theFileIsOnlyReadableAndWritableByItsOwner() throws {
        let fileURL = temporaryHistoryURL()
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

    private func corruptHistoryURL() throws -> URL {
        let fileURL = temporaryHistoryURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("invalid JSON".utf8).write(to: fileURL)
        return fileURL
    }

    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "history.json", directoryHint: .notDirectory)
    }
}
