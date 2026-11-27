import Combine
import Darwin
import Foundation

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

    public static var defaultFileURL: URL {
        WhisperModelConfiguration.defaultCacheRoot
            .deletingLastPathComponent()
            .appending(path: "history.json", directoryHint: .notDirectory)
    }

    @Published public private(set) var entries: [Entry]
    @Published public private(set) var lastSaveFailed: Bool = false

    private let fileURL: URL
    private let now: () -> Date
    private var requiresQuarantine = false

    public init(
        fileURL: URL = DictationHistory.defaultFileURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try JSONDecoder().decode([Entry].self, from: data)
            entries = Array(stored.prefix(Self.capacity))
        } catch {
            entries = []
            var fileStatus = stat()
            let status = lstat(fileURL.path, &fileStatus)
            requiresQuarantine = status == 0 || errno != ENOENT
        }
    }

    public func add(id: UUID, text: String) {
        let entry = Entry(
            id: id,
            text: text,
            date: now()
        )
        let recent = [entry] + entries
        let updated = Array(recent.prefix(Self.capacity))
        do {
            try quarantineUnreadableFileIfNeeded(at: entry.date)
            try persist(updated)
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
        }
        entries = updated
    }

    private func quarantineUnreadableFileIfNeeded(at date: Date) throws {
        guard requiresQuarantine else { return }
        let timestamp = date.timeIntervalSince1970.rounded(.down)
        guard let unixSeconds = Int64(exactly: timestamp) else {
            throw DictationHistoryError.invalidArchiveTimestamp
        }
        let archive = fileURL.deletingLastPathComponent().appending(
            path: "history-unreadable-\(unixSeconds).json",
            directoryHint: .notDirectory
        )
        try FileManager.default.moveItem(at: fileURL, to: archive)
        requiresQuarantine = false
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
    case invalidArchiveTimestamp
    case replacementFailed
}
