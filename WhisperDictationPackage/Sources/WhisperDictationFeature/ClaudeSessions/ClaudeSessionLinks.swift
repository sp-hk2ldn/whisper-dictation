import Foundation

struct ClaudeSessionLinks: Sendable {
    static let newTask = URL(string: "claude://code/new")!
    static let waiting = URL(string: "claude://code/needs-input")!
    private static let lastSession = "last"

    func url(for slot: ClaudeSlot, localID: String?) -> URL? {
        switch slot.state {
        case .awaitingApproval, .awaitingResponse:
            link(path: "/needs-input", session: localID)
        case .idle, .working, .unread, .error:
            link(path: "/continue", session: localID ?? Self.lastSession)
        }
    }

    private func link(path: String, session: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = path
        components.queryItems = session.map {
            [URLQueryItem(name: "session", value: $0)]
        }
        return components.url
    }
}
