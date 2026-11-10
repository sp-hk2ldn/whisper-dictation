import AppKit
import Foundation

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private let resultURL: URL
    private let recreatesTarget: Bool
    private var textView = NSTextView()
    private var scrollView: NSScrollView?
    private var window: NSWindow?
    private var resultTimer: Timer?
    private var recreationTimer: Timer?
    private var recreationCount = 0

    init(resultURL: URL, recreatesTarget: Bool) {
        self.resultURL = resultURL
        self.recreatesTarget = recreatesTarget
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 220)
        )
        scrollView.hasVerticalScroller = true

        configure(
            textView,
            text: "START:",
            identifier: "InsertionTarget-0"
        )
        scrollView.documentView = textView
        self.scrollView = scrollView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Dictation Insertion Harness"
        window.contentView = scrollView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(
            NSRange(location: textView.string.utf16.count, length: 0)
        )
        self.window = window

        writeResult()
        resultTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusTarget()
                self?.writeResult()
            }
        }
        if recreatesTarget {
            recreationTimer = Timer.scheduledTimer(
                withTimeInterval: 0.1,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recreateTarget()
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func textDidChange(_ notification: Notification) {
        writeResult()
    }

    private func focusTarget() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func recreateTarget() {
        let text = textView.string
        let selectedRange = textView.selectedRange()
        recreationCount += 1

        let replacement = NSTextView()
        configure(
            replacement,
            text: text,
            identifier: "InsertionTarget-\(recreationCount)"
        )
        scrollView?.documentView = replacement
        textView = replacement
        textView.setSelectedRange(selectedRange)
        focusTarget()
        writeResult()

        if recreationCount >= 50 {
            recreationTimer?.invalidate()
            recreationTimer = nil
        }
    }

    private func configure(
        _ target: NSTextView,
        text: String,
        identifier: String
    ) {
        target.string = text
        target.font = .systemFont(ofSize: 18)
        target.delegate = self
        target.setAccessibilityIdentifier(identifier)
    }

    private func writeResult() {
        try? textView.string
            .data(using: .utf8)?
            .write(to: resultURL, options: .atomic)
    }
}

let resultPath = CommandLine.arguments
    .first(where: { $0.hasPrefix("--result=") })?
    .dropFirst("--result=".count)
    .description
    ?? "/private/tmp/whisperdictation-insertion-result.txt"
let recreatesTarget = CommandLine.arguments.contains("--recreate-target")

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = HarnessDelegate(
    resultURL: URL(fileURLWithPath: resultPath),
    recreatesTarget: recreatesTarget
)
application.delegate = delegate
application.run()
