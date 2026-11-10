import Foundation

public enum MicroSurface: String, CaseIterable, Identifiable, Sendable {
    case claudeApp = "claude-app"
    case t3Code = "t3-code"
    case codex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeApp: "Claude"
        case .t3Code: "T3 Code"
        case .codex: "Codex"
        }
    }

    var host: ClaudeSessionHost? {
        switch self {
        case .claudeApp: .claudeDesktop
        case .t3Code: .t3Code
        case .codex: nil
        }
    }
}
