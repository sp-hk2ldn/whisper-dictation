import CoreServices
import Foundation

struct ClaudeDesktopSession: Equatable, Sendable {
    let localID: String
    let cliSessionID: String
    let lastFocusedAt: Date?
}

struct ClaudeDesktopFileEntry: Equatable, Sendable {
    let path: String
    let modifiedAt: Date
    let session: ClaudeDesktopSession?
}

struct ClaudeDesktopIndex: Equatable, Sendable {
    private struct FocusStamp {
        let cliSessionID: String
        let focusedAt: Date
    }

    static let empty = ClaudeDesktopIndex(entries: [])

    let entries: [ClaudeDesktopFileEntry]

    var focusedCLISessionID: String? {
        sessions
            .compactMap { session in
                session.lastFocusedAt.map {
                    FocusStamp(cliSessionID: session.cliSessionID, focusedAt: $0)
                }
            }
            .max { $0.focusedAt < $1.focusedAt }?
            .cliSessionID
    }

    private var sessions: [ClaudeDesktopSession] {
        entries.compactMap { $0.session }
    }

    func localID(for cliSessionID: String) -> String? {
        sessions.first { $0.cliSessionID == cliSessionID }?.localID
    }
}

struct ClaudeDesktopResolution: Equatable, Sendable {
    let localID: String?
    let index: ClaudeDesktopIndex
}

struct ClaudeDesktopSessionStore: Sendable {
    private struct SessionFile {
        let url: URL
        let modifiedAt: Date
    }

    private struct SessionFileDTO: Decodable {
        private enum CodingKeys: String, CodingKey {
            case sessionId
            case cliSessionId
            case lastFocusedAt
        }

        let sessionId: String
        let cliSessionId: String
        let lastFocusedAt: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            cliSessionId = try container.decode(String.self, forKey: .cliSessionId)
            lastFocusedAt = try? container.decodeIfPresent(
                Double.self,
                forKey: .lastFocusedAt
            )
        }

        func toSession() -> ClaudeDesktopSession? {
            guard
                sessionId.range(
                    of: ClaudeDesktopSessionStore.localIDPattern,
                    options: .regularExpression
                ) != nil,
                !cliSessionId.isEmpty
            else { return nil }
            return ClaudeDesktopSession(
                localID: sessionId,
                cliSessionID: cliSessionId,
                lastFocusedAt: lastFocusedAt.map {
                    Date(timeIntervalSince1970: $0 / 1000)
                }
            )
        }
    }

    private static let localIDPattern = "^local_[A-Za-z0-9-]{1,64}\\z"
    private static let sessionFilePrefix = "local_"

    let root: URL

    static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "Claude", directoryHint: .isDirectory)
            .appending(path: "claude-code-sessions", directoryHint: .isDirectory)
    }

    func scan(reusing previous: ClaudeDesktopIndex) -> ClaudeDesktopIndex {
        let reusable = Dictionary(
            previous.entries.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ClaudeDesktopIndex(
            entries: sessionFiles().map { entry(for: $0, reusing: reusable) }
        )
    }

    func resolving(
        _ cliSessionID: String,
        in cached: ClaudeDesktopIndex
    ) -> ClaudeDesktopResolution {
        let cachedID = cached.localID(for: cliSessionID)
        guard cachedID == nil else {
            return ClaudeDesktopResolution(localID: cachedID, index: cached)
        }
        let rescanned = scan(reusing: cached)
        return ClaudeDesktopResolution(
            localID: rescanned.localID(for: cliSessionID),
            index: rescanned
        )
    }

    private func entry(
        for file: SessionFile,
        reusing reusable: [String: ClaudeDesktopFileEntry]
    ) -> ClaudeDesktopFileEntry {
        guard
            let known = reusable[file.url.path],
            known.modifiedAt == file.modifiedAt
        else { return read(file) }
        return known
    }

    private func read(_ file: SessionFile) -> ClaudeDesktopFileEntry {
        let session = (try? Data(contentsOf: file.url))
            .flatMap { try? JSONDecoder().decode(SessionFileDTO.self, from: $0) }
            .flatMap { $0.toSession() }
        return ClaudeDesktopFileEntry(
            path: file.url.path,
            modifiedAt: file.modifiedAt,
            session: session
        )
    }

    private func sessionFiles() -> [SessionFile] {
        contents(of: root)
            .flatMap { contents(of: $0) }
            .flatMap { contents(of: $0) }
            .filter {
                $0.lastPathComponent.hasPrefix(Self.sessionFilePrefix)
                    && $0.pathExtension == "json"
            }
            .compactMap { url in
                modifiedDate(of: url).map { SessionFile(url: url, modifiedAt: $0) }
            }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func modifiedDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}

final class ClaudeDesktopWatcher: @unchecked Sendable {
    private static let latency: CFTimeInterval = 0.5

    private let store: ClaudeDesktopSessionStore
    private let queue = DispatchQueue(
        label: "WhisperDictation.claude-desktop",
        qos: .utility
    )
    private let onChange: @Sendable (ClaudeDesktopIndex) -> Void
    private var stream: FSEventStreamRef?
    private var index = ClaudeDesktopIndex.empty

    init(
        store: ClaudeDesktopSessionStore,
        onChange: @escaping @Sendable (ClaudeDesktopIndex) -> Void
    ) {
        self.store = store
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            guard
                let created = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    { _, info, _, _, _, _ in
                        guard let info else { return }
                        Unmanaged<ClaudeDesktopWatcher>
                            .fromOpaque(info)
                            .takeUnretainedValue()
                            .publish()
                    },
                    &context,
                    [store.root.path] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    Self.latency,
                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
                )
            else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
            publish()
        }
    }

    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func publish() {
        index = store.scan(reusing: index)
        onChange(index)
    }
}
