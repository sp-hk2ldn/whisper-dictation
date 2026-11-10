import Foundation
import Testing
@testable import WhisperDictationFeature

struct T3SessionLinksTests {
    @Test(arguments: [
        (Optional("env-1"), Optional("thread-1"), Optional("t3code://threads/env-1/thread-1")),
        (nil, Optional("thread-1"), nil),
        (Optional("env-1"), nil, nil)
    ])
    func linksNeedBothIDs(environment: String?, thread: String?, expected: String?) {
        let record = ClaudeSessionRecord(
            sessionID: "s",
            state: .idle,
            cwd: "/work",
            updatedAt: Date(timeIntervalSince1970: 0),
            host: .t3Code,
            threadID: thread,
            environmentID: environment
        )
        #expect(T3SessionLinks().url(for: record)?.absoluteString == expected)
    }
}
