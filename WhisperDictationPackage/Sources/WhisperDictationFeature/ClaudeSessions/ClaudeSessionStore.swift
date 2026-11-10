import Foundation

struct ClaudeSessionStore: Sendable {
    static let maximumAge: TimeInterval = 24 * 60 * 60

    let directory: URL

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Whisper Dictation", directoryHint: .isDirectory)
            .appending(path: "claude-sessions", directoryHint: .isDirectory)
    }

    func records(now: Date) -> [ClaudeSessionRecord] {
        let all = sessionFiles().compactMap(record(at:))
        let expired = all.filter { isExpired($0, now: now) }
        expired.forEach { remove($0) }
        return all.filter { !isExpired($0, now: now) }
    }

    func createDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func sessionFiles() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? []).filter { $0.pathExtension == "json" }
    }

    private func record(at url: URL) -> ClaudeSessionRecord? {
        guard
            let data = try? Data(contentsOf: url),
            let file = try? Self.decoder.decode(ClaudeSessionFile.self, from: data)
        else { return nil }
        return file.toRecord(sessionID: url.deletingPathExtension().lastPathComponent)
    }

    private func isExpired(_ record: ClaudeSessionRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.updatedAt) > Self.maximumAge
    }

    private func remove(_ record: ClaudeSessionRecord) {
        let url = directory
            .appending(path: record.sessionID)
            .appendingPathExtension("json")
        try? FileManager.default.removeItem(at: url)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class ClaudeSessionWatcher: @unchecked Sendable {
    private let store: ClaudeSessionStore
    private let queue = DispatchQueue(
        label: "WhisperDictation.claude-sessions",
        qos: .utility
    )
    private let onChange: @Sendable ([ClaudeSessionRecord]) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(
        store: ClaudeSessionStore,
        onChange: @escaping @Sendable ([ClaudeSessionRecord]) -> Void
    ) {
        self.store = store
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard source == nil else { return }
            store.createDirectory()
            let descriptor = open(store.directory.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.publish() }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
            publish()
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    private func publish() {
        onChange(store.records(now: Date()))
    }
}
