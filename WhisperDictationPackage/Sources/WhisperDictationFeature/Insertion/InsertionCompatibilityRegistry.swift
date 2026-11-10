import Foundation

enum InsertionRoute: Sendable, Equatable {
    case accessibilityThenPaste
    case pasteOnly
}

struct InsertionCompatibilityProfile: Sendable, Equatable {
    let route: InsertionRoute
    let pasteboardRestoreDelay: Duration
}

enum KnownTextDestination: String, Sendable {
    // The Codex CLI and the ChatGPT desktop app both ship with bundle
    // identifier `com.openai.codex` — OpenAI rebranded the desktop chat
    // app but kept the bundle id, so a single registry entry covers
    // both. If either app ever changes its bundle id, add a new case
    // here rather than renaming this one.
    case codex = "com.openai.codex"
    // Hermes is an Electron app that wraps its CodeMirror chat input in
    // multiple React <div>s. Chromium exposes the focused element as
    // `AXGroup` (a wrapper) rather than the inner `AXTextArea`, which means
    // `isEligibleTextTarget` rejects capture. Routing directly to paste
    // skips the AX-set path; Chromium's clipboard observer delivers the
    // paste to the contenteditable's DOM focus.
    case hermes = "com.nousresearch.hermes"
    // The Claude desktop app is Electron too, so it takes the same paste
    // route as Hermes.
    case claude = "com.anthropic.claudefordesktop"
}

enum InsertionCompatibilityRegistry {
    private static let routeOverrides: [
        KnownTextDestination: InsertionCompatibilityProfile
    ] = [
        .codex: InsertionCompatibilityProfile(
            route: .pasteOnly,
            pasteboardRestoreDelay: .seconds(2)
        ),
        .hermes: InsertionCompatibilityProfile(
            route: .pasteOnly,
            pasteboardRestoreDelay: .milliseconds(1500)
        ),
        .claude: InsertionCompatibilityProfile(
            route: .pasteOnly,
            pasteboardRestoreDelay: .milliseconds(1500)
        ),
    ]

    private static let defaultProfile = InsertionCompatibilityProfile(
        route: .accessibilityThenPaste,
        pasteboardRestoreDelay: .milliseconds(300)
    )

    static func profile(
        for bundleIdentifier: String?
    ) -> InsertionCompatibilityProfile {
        guard
            let bundleIdentifier,
            let destination = KnownTextDestination(
                rawValue: bundleIdentifier
            )
        else {
            return defaultProfile
        }

        return routeOverrides[destination] ?? defaultProfile
    }
}
