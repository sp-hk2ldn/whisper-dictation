import Foundation

enum ClaudeSessionState: String, Sendable, Equatable, Decodable {
    case idle
    case working
    case unread
    case awaitingApproval = "awaiting-approval"
    case awaitingResponse = "awaiting-response"
    case error
}

enum ClaudeSessionHost: String, Sendable, Equatable, Decodable {
    case claudeDesktop = "claude-desktop"
    case t3Code = "t3-code"
}

struct ClaudeSessionRecord: Sendable, Equatable {
    let sessionID: String
    let state: ClaudeSessionState
    let cwd: String
    let updatedAt: Date
    let host: ClaudeSessionHost
    let threadID: String?
    let environmentID: String?

    init(
        sessionID: String,
        state: ClaudeSessionState,
        cwd: String,
        updatedAt: Date,
        host: ClaudeSessionHost,
        threadID: String?,
        environmentID: String? = nil
    ) {
        self.sessionID = sessionID
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.host = host
        self.threadID = threadID
        self.environmentID = environmentID
    }

    init(
        sessionID: String,
        state: ClaudeSessionState,
        cwd: String,
        updatedAt: Date
    ) {
        self.init(
            sessionID: sessionID,
            state: state,
            cwd: cwd,
            updatedAt: updatedAt,
            host: .claudeDesktop,
            threadID: nil
        )
    }
}

struct ClaudeSessionFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case state, cwd, updatedAt, host, threadID, environmentID
    }

    let host: ClaudeSessionHost
    let threadID: String?
    let environmentID: String?
    let state: ClaudeSessionState
    let cwd: String
    let updatedAt: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(ClaudeSessionState.self, forKey: .state)
        cwd = try container.decode(String.self, forKey: .cwd)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        host = container.contains(.host)
            ? try container.decode(ClaudeSessionHost.self, forKey: .host)
            : .claudeDesktop
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID)
    }

    func toRecord(sessionID: String) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            sessionID: sessionID,
            state: state,
            cwd: cwd,
            updatedAt: updatedAt,
            host: host,
            threadID: threadID,
            environmentID: environmentID
        )
    }
}
