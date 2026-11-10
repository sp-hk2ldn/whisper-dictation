@preconcurrency import AppKit
import Carbon
import SwiftUI

public struct DictationSettingsView: View {
    @ObservedObject private var runtime: DictationRuntime
    @StateObject private var shortcutRecorder = ShortcutRecorderState()

    public init(runtime: DictationRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        Form {
            LabeledContent("Push-to-talk shortcut") {
                Button {
                    if shortcutRecorder.isRecording {
                        shortcutRecorder.cancel()
                    } else {
                        shortcutRecorder.start(
                            onBegin: {
                                runtime.beginHotkeyCapture()
                            },
                            onCommit: { chord in
                                runtime.setHotkeyChord(chord)
                            },
                            onCancel: {
                                runtime.cancelHotkeyCapture()
                            }
                        )
                    }
                } label: {
                    Text(
                        shortcutRecorder.isRecording
                            ? "Press shortcut…"
                            : runtime.hotkeyChord.title
                    )
                    .monospacedDigit()
                    .frame(minWidth: 130)
                }
            }

            Text(
                shortcutRecorder.isRecording
                    ? "Press Escape to cancel."
                    : "Use at least two modifiers, or choose F13–F20."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            LabeledContent("Microphone") {
                permissionLabel(
                    granted: runtime.microphoneAuthorization == .authorized
                )
            }

            if runtime.microphoneAuthorization != .authorized {
                Button("Request Microphone Access") {
                    Task {
                        await runtime.requestMicrophone()
                    }
                }
            }

            LabeledContent("Accessibility") {
                permissionLabel(granted: runtime.accessibilityGranted)
            }

            if !runtime.accessibilityGranted {
                Button("Enable Accessibility") {
                    runtime.requestAccessibility()
                }
            }

            LabeledContent("Local model") {
                Text(modelStatus)
                    .foregroundStyle(
                        runtime.modelReadiness == .ready ? .green : .secondary
                    )
            }

            if runtime.modelReadiness != .ready {
                Button(
                    runtime.modelReadiness == .loading
                        ? "Downloading…"
                        : "Download Local Model"
                ) {
                    Task {
                        await runtime.prepareModel()
                    }
                }
                .disabled(runtime.modelReadiness == .loading)
            }

            if let error = runtime.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            shortcutRecorder.cancel()
        }
    }

    private func permissionLabel(granted: Bool) -> some View {
        Label(
            granted ? "Allowed" : "Required",
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .foregroundStyle(granted ? .green : .orange)
    }

    private var modelStatus: String {
        switch runtime.modelReadiness {
        case .notInstalled:
            "Not installed"
        case .loading:
            "Downloading and preparing"
        case .ready:
            "Ready"
        case .failed:
            "Needs attention"
        }
    }
}

@MainActor
private final class ShortcutRecorderState: ObservableObject {
    @Published private(set) var isRecording = false

    private var eventMonitor: Any?
    private var commitHandler: ((HotkeyChord) -> Void)?
    private var cancelHandler: (() -> Void)?

    func start(
        onBegin: () -> Void,
        onCommit: @escaping (HotkeyChord) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isRecording else { return }
        isRecording = true
        commitHandler = onCommit
        cancelHandler = onCancel
        onBegin()

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            let keyCode = event.keyCode
            let modifierRawValue = event.modifierFlags.rawValue
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isRecording else { return false }

                if Int(keyCode) == kVK_Escape {
                    self.cancel()
                    return true
                }

                let chord = HotkeyChord(
                    keyCode: UInt32(keyCode),
                    modifiers: Self.carbonModifiers(
                        from: NSEvent.ModifierFlags(
                            rawValue: modifierRawValue
                        )
                    )
                )
                self.commit(chord)
                return true
            }
            return consumed ? nil : event
        }
    }

    func cancel() {
        guard isRecording else { return }
        let handler = cancelHandler
        stop()
        handler?()
    }

    private func commit(_ chord: HotkeyChord) {
        let handler = commitHandler
        stop()
        handler?(chord)
    }

    private func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        commitHandler = nil
        cancelHandler = nil
        isRecording = false
    }

    private static func carbonModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        return modifiers
    }
}
