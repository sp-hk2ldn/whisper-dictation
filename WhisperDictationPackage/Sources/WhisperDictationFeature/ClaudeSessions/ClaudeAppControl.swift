import AppKit
import Carbon

enum ClaudeKeystroke: String, Equatable, Sendable {
    case returnKey = "Return"
    case escape = "Escape"
}

struct FrontmostApplication: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

@MainActor
protocol ClaudeAppControlling {
    func frontmostApplication() -> FrontmostApplication?
    func open(_ url: URL)
    func activateT3Code() -> Bool
    func post(_ keystroke: ClaudeKeystroke, toProcess processIdentifier: pid_t) -> Bool
}

@MainActor
struct SystemClaudeApp: ClaudeAppControlling {
    func frontmostApplication() -> FrontmostApplication? {
        NSWorkspace.shared.frontmostApplication.map {
            FrontmostApplication(
                bundleIdentifier: $0.bundleIdentifier,
                processIdentifier: $0.processIdentifier
            )
        }
    }

    func open(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    func activateT3Code() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.t3tools.t3code"
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func post(_ keystroke: ClaudeKeystroke, toProcess processIdentifier: pid_t) -> Bool {
        let keyCode = keyCode(for: keystroke)
        guard
            AXIsProcessTrusted(),
            let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: true
            ),
            let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: false
            )
        else { return false }
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }

    private func keyCode(for keystroke: ClaudeKeystroke) -> CGKeyCode {
        switch keystroke {
        case .returnKey: CGKeyCode(kVK_Return)
        case .escape: CGKeyCode(kVK_Escape)
        }
    }
}
