import Foundation

struct T3SessionLinks: Sendable {
    static let newThread = URL(string: "t3code://new")!

    func url(for record: ClaudeSessionRecord) -> URL? {
        guard let environmentID = record.environmentID, let threadID = record.threadID else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "t3code"
        components.host = "threads"
        components.path = "/\(environmentID)/\(threadID)"
        return components.url
    }
}
