import SwiftUI

public struct RecentDictationsView: View {
    private enum CopyOutcome: Equatable {
        case copied(UUID)
        case failed(UUID)
    }

    private static let scrollThreshold = 3
    private static let scrollHeight: CGFloat = 220

    @ObservedObject var history: DictationHistory
    let copy: @MainActor (UUID) -> Bool

    @State private var outcome: CopyOutcome?
    @State private var hoveredID: UUID?

    public init(
        history: DictationHistory,
        copy: @escaping @MainActor (UUID) -> Bool
    ) {
        self.history = history
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            HStack {
                Text("Recent dictations")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let latest = history.entries.first {
                    Button(status(for: latest.id) ?? "Copy last") {
                        copyEntry(latest.id)
                    }
                    .controlSize(.small)
                    .accessibilityHint("Copies your most recent dictation to the clipboard")
                }
            }

            if history.lastSaveFailed {
                Text("Couldn't save history. New dictations will be lost when you quit.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            entryList
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(width: 300)
        .task(id: outcome) {
            guard outcome != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            outcome = nil
        }
        .onDisappear { outcome = nil }
    }

    @ViewBuilder
    private var entryList: some View {
        if history.entries.isEmpty {
            Text("Nothing yet. Your last \(DictationHistory.capacity) dictations will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if history.entries.count <= Self.scrollThreshold {
            rows
        } else {
            ScrollView { rows }
                .frame(height: Self.scrollHeight)
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(history.entries) { entry in
                row(for: entry)
            }
        }
    }

    private func row(for entry: DictationHistory.Entry) -> some View {
        let date = entry.date.formatted(.relative(presentation: .named))
        let status = status(for: entry.id)
        return Button {
            copyEntry(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status ?? date)
                    .font(.caption2)
                    .foregroundStyle(status == nil ? .secondary : Color.accentColor)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill(for: entry.id))
        )
        .onHover { isHovering in
            hoveredID = isHovering ? entry.id : nil
        }
        .accessibilityLabel(entry.text)
        .accessibilityValue(status ?? date)
        .accessibilityHint("Copies this dictation to the clipboard")
    }

    private func rowFill(for id: UUID) -> Color {
        switch (status(for: id), hoveredID == id) {
        case (.some, _): Color.accentColor.opacity(0.12)
        case (nil, true): Color.primary.opacity(0.06)
        case (nil, false): .clear
        }
    }

    private func status(for id: UUID) -> String? {
        switch outcome {
        case .copied(id): "Copied"
        case .failed(id): "Couldn't copy"
        default: nil
        }
    }

    private func copyEntry(_ id: UUID) {
        let copied = copy(id)
        outcome = copied ? .copied(id) : .failed(id)
        AccessibilityNotification.Announcement(copied ? "Copied" : "Couldn't copy").post()
    }
}
