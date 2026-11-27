//
//  DictationHistory.swift
//  WhisperDictation
//
//  Created by Stephen Parker on 27/11/2026.
//

import Combine
import Darwin
import Foundation
import OSLog

@MainActor
public final class DictationHistory: ObservableObject {
    public struct Entry: Codable, Equatable, Identifiable {
        public let id: UUID
        public let text: String
        public let date: Date
    }

    private static let capacity = 20
    private static let privateDirectoryPermissions = 0o700
    private static let privateFilePermissions = 0o600
    private static let logger = Logger(
        subsystem: "io.github.sp-hk2ldn.WhisperDictation",
        category: "DictationHistory"
    )

    public static var defaultFileURL: URL {
        WhisperModelConfiguration.defaultCacheRoot
            .deletingLastPathComponent()
            .appending(path: "history.json", directoryHint: .notDirectory)
    }

    @Published public private(set) var entries: [Entry]

    private let fileURL: URL
    private let now: () -> Date

    public init(
        fileURL: URL = DictationHistory.defaultFileURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        entries = Self.loadEntries(from: fileURL)
    }

    public func add(id: UUID, text: String) {
        let entry = Entry(
            id: id,
            text: text,
            date: now()
        )
        let recent = [entry] + entries.filter { $0.id != id }
        let updated = Array(recent.prefix(Self.capacity))
        do {
            try persist(updated)
        } catch {
            Self.logger.error("Unable to save dictation history.")
        }
        entries = updated
    }

    private static func loadEntries(from fileURL: URL) -> [Entry] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }

        return Array(stored.prefix(capacity))
    }

    private func persist(_ entries: [Entry]) throws {
        let data = try JSONEncoder().encode(entries)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileURL,
            create: true
        )
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        try fileManager.setAttributes(
            [.posixPermissions: Self.privateDirectoryPermissions],
            ofItemAtPath: replacementDirectory.path
        )

        let replacement = replacementDirectory.appending(path: fileURL.lastPathComponent)
        try data.write(to: replacement)
        try fileManager.setAttributes(
            [.posixPermissions: Self.privateFilePermissions],
            ofItemAtPath: replacement.path
        )
        guard rename(replacement.path, fileURL.path) == 0 else {
            throw DictationHistoryError.replacementFailed
        }
    }
}

private enum DictationHistoryError: Error {
    case replacementFailed
}
