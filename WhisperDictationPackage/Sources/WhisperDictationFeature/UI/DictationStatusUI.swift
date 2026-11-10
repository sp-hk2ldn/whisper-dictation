import SwiftUI

/// UI actions are supplied by the application layer so this package's views do
/// not own session, pasteboard, or application-lifecycle behavior.
@MainActor
public struct DictationUIActions {
    public var cancel: @MainActor () async -> Void
    public var copyRecoveryText: @MainActor () -> Void
    public var dismissOutcome: @MainActor () -> Void
    public var openSettings: @MainActor () -> Void
    public var quit: @MainActor () -> Void

    public init(
        cancel: @escaping @MainActor () async -> Void = {},
        copyRecoveryText: @escaping @MainActor () -> Void = {},
        dismissOutcome: @escaping @MainActor () -> Void = {},
        openSettings: @escaping @MainActor () -> Void = {},
        quit: @escaping @MainActor () -> Void = {}
    ) {
        self.cancel = cancel
        self.copyRecoveryText = copyRecoveryText
        self.dismissOutcome = dismissOutcome
        self.openSettings = openSettings
        self.quit = quit
    }
}

/// Compact content appropriate for a non-activating HUD panel. The host owns
/// panel activation policy; this view deliberately has no focusable inputs.
public struct DictationStatusHUDContent: View {
    public let phase: DictationSessionCoordinator.Phase
    public let recoveryText: String?
    public let actions: DictationUIActions

    public init(
        phase: DictationSessionCoordinator.Phase,
        recoveryText: String? = nil,
        actions: DictationUIActions = .init()
    ) {
        self.phase = phase
        self.recoveryText = recoveryText
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.title, systemImage: status.symbolName)
                .font(.headline)
                .foregroundStyle(status.tint)
                .accessibilityAddTraits(.isHeader)

            Text(status.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let recoveryText, !recoveryText.isEmpty {
                Text(recoveryText)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityLabel("Recovered dictation")

                HStack {
                    Button("Copy Text") {
                        actions.copyRecoveryText()
                    }
                    .accessibilityHint(
                        "Copies the recovered dictation to the clipboard"
                    )

                    Button("Discard", role: .cancel) {
                        actions.dismissOutcome()
                    }
                    .accessibilityHint(
                        "Discards the recovered dictation without changing the clipboard"
                    )
                }
            }

            if phase == .failed {
                Button("Dismiss") {
                    actions.dismissOutcome()
                }
                .accessibilityHint(
                    "Returns to ready state without inserting text"
                )
            }

            if status.canCancel {
                Button("Cancel", role: .cancel) {
                    run(actions.cancel)
                }
                .accessibilityHint("Discards this dictation without inserting text")
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    private var status: DictationStatus {
        DictationStatus(phase: phase)
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            await action()
        }
    }
}

/// Menu-bar popover content. It intentionally stays separate from the HUD so
/// the application can present either surface without changing session state.
public struct DictationMenuPopoverContent: View {
    public let phase: DictationSessionCoordinator.Phase
    public let recoveryText: String?
    public let actions: DictationUIActions

    public init(
        phase: DictationSessionCoordinator.Phase,
        recoveryText: String? = nil,
        actions: DictationUIActions = .init()
    ) {
        self.phase = phase
        self.recoveryText = recoveryText
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DictationStatusHUDContent(
                phase: phase,
                recoveryText: recoveryText,
                actions: actions
            )
            .padding(0)

            Divider()

            HStack {
                Button("Settings…") {
                    actions.openSettings()
                }
                .accessibilityHint("Opens dictation settings")

                Spacer()

                Button("Quit") {
                    actions.quit()
                }
                .accessibilityHint("Quits the dictation app")
            }
            .controlSize(.small)
        }
        .frame(width: 300)
        .padding(12)
    }

}

private struct DictationStatus {
    let title: String
    let detail: String
    let symbolName: String
    let tint: Color
    let canCancel: Bool

    init(phase: DictationSessionCoordinator.Phase) {
        switch phase {
        case .idle:
            title = "Ready"
            detail = "Hold your dictation shortcut to speak."
            symbolName = "mic"
            tint = .secondary
            canCancel = false
        case .recording:
            title = "Recording"
            detail = "Release the shortcut when you are finished."
            symbolName = "record.circle.fill"
            tint = .red
            canCancel = true
        case .transcribing:
            title = "Transcribing"
            detail = "Processing speech locally."
            symbolName = "waveform"
            tint = .blue
            canCancel = true
        case .inserting:
            title = "Inserting"
            detail = "Adding the final transcript at the original cursor."
            symbolName = "text.cursor"
            tint = .accentColor
            canCancel = true
        case .needsRecovery:
            title = "Text Not Inserted"
            detail = "No suitable text field was available. Your text is kept below."
            symbolName = "exclamationmark.triangle.fill"
            tint = .orange
            canCancel = false
        case .failed:
            title = "Dictation Failed"
            detail = "No text was inserted. Try again when ready."
            symbolName = "xmark.circle.fill"
            tint = .red
            canCancel = false
        }
    }
}
