import AppKit
import AVFoundation
import Combine
import SwiftUI

/// A draggable status surface that never becomes key or changes the insertion target.
@MainActor
public final class FloatingDictationStatusController {
    private let panel: NSPanel
    private var subscriptions = Set<AnyCancellable>()
    private let positionKey = "floatingDictationStatusOrigin"

    public init(runtime: DictationRuntime) {
        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 264, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = DraggableStatusHostingView(rootView: FloatingDictationStatus(runtime: runtime))
        content.didFinishDragging = { [weak self] in
            guard let self else { return }
            savePosition()
            positionPanel()
        }
        content.toolTip = "Drag to move"
        panel.contentView = content

        Publishers.CombineLatest(runtime.coordinator.$phase, runtime.$lastError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                if !panel.isVisible { positionPanel() }
                panel.orderFrontRegardless()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.positionPanel() }
            .store(in: &subscriptions)
    }

    private func positionPanel() {
        if let coordinates = UserDefaults.standard.array(forKey: positionKey) as? [Double],
           coordinates.count == 2, coordinates.allSatisfy({ $0.isFinite }) {
            let savedFrame = NSRect(origin: NSPoint(x: coordinates[0], y: coordinates[1]), size: panel.frame.size)
            let screen = NSScreen.screens.max { lhs, rhs in
                let left = lhs.visibleFrame.intersection(savedFrame)
                let right = rhs.visibleFrame.intersection(savedFrame)
                return (left.isNull ? 0 : left.width * left.height)
                    < (right.isNull ? 0 : right.width * right.height)
            }
            let target = screen.flatMap { $0.visibleFrame.intersects(savedFrame) ? $0 : nil }
                ?? NSScreen.main ?? NSScreen.screens.first
            guard let target else { return }
            let frame = target.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: min(max(savedFrame.minX, frame.minX), max(frame.minX, frame.maxX - panel.frame.width)),
                y: min(max(savedFrame.minY, frame.minY), max(frame.minY, frame.maxY - panel.frame.height))
            ))
            return
        }
        let screen = panel.isVisible ? panel.screen : NSScreen.main
        guard let screen = screen ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(
            x: frame.maxX - panel.frame.width - 12,
            y: frame.maxY - 12
        ))
    }

    private func savePosition() {
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.minY)], forKey: positionKey)
    }
}

private final class DraggableStatusHostingView<Content: View>: NSHostingView<Content> {
    var didFinishDragging: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        window?.performDrag(with: event)
        didFinishDragging?()
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct FloatingDictationStatus: View {
    @State private var showsCompletion = false
    @ObservedObject var runtime: DictationRuntime
    @ObservedObject var coordinator: DictationSessionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(runtime: DictationRuntime) {
        self.runtime = runtime
        coordinator = runtime.coordinator
    }

    private var isReady: Bool {
        coordinator.phase == .idle && runtime.lastError == nil
            && runtime.modelReadiness == .ready
            && runtime.accessibilityGranted
            && runtime.microphoneAuthorization == .authorized
    }

    private var idleTitle: String {
        if runtime.lastError != nil { return "Needs attention" }
        if runtime.modelReadiness == .loading { return "Preparing model" }
        return isReady ? "Ready" : "Setup needed"
    }

    private var title: String {
        if showsCompletion && isReady { return "Inserted" }
        return switch coordinator.phase {
        case .idle: idleTitle
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .inserting: "Inserting"
        case .needsRecovery: coordinator.recoveryCopied ? "Copied to clipboard" : "Text not inserted"
        case .failed: coordinator.failureDiagnostic?.contains("emptyTranscript") == true
            ? "No text recognised" : "Dictation failed"
        }
    }

    private var detail: String {
        if showsCompletion && isReady { return "Text added at your cursor" }
        return switch coordinator.phase {
        case .idle: isReady ? "Hold \(runtime.hotkeyChord.title) to speak" : "Open the menu bar for details"
        case .recording: coordinator.pendingCount > 0
            ? "Recording · \(coordinator.pendingCount) processing" : "Release shortcut to finish"
        case .transcribing: "Processing on your Mac"
        case .inserting: "Adding text at your cursor"
        case .needsRecovery: coordinator.recoveryCopied ? "Paste it wherever you need" : "Open the menu bar to copy"
        case .failed: coordinator.failureDiagnostic?.contains("emptyTranscript") == true
            ? "One phrase returned no text" : "Open the menu bar for details"
        }
    }

    private var isWorking: Bool {
        coordinator.phase == .recording || coordinator.phase == .transcribing || coordinator.phase == .inserting
    }

    private var symbol: String {
        if showsCompletion && isReady { return "checkmark" }
        return switch coordinator.phase {
        case .idle: isReady ? "mic" : "exclamationmark"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .inserting: "text.cursor"
        default: "exclamationmark"
        }
    }

    private var orbColors: [Color] {
        if showsCompletion && isReady { return [.mint, .green, .cyan, .mint] }
        switch coordinator.phase {
        case .recording: return [.pink, .red, .purple, .pink]
        case .transcribing: return [.cyan, .blue, .purple, .cyan]
        case .inserting: return [.mint, .green, .cyan, .mint]
        default:
            return isReady
                ? [.mint.opacity(0.6), .cyan.opacity(0.5), .mint.opacity(0.6), .mint.opacity(0.6)]
                : [.orange, .pink, .orange, .orange]
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || !isWorking)) { context in
                let time = reduceMotion || !isWorking ? 0 : context.date.timeIntervalSinceReferenceDate
                let pulse = 1 + 0.06 * sin(time * 3)
                ZStack {
                    Circle()
                        .fill(AngularGradient(
                            colors: orbColors,
                            center: .center, angle: .degrees(time.truncatingRemainder(dividingBy: 8) * 45)
                        ))
                        .blur(radius: 3)
                        .scaleEffect(pulse)
                    Circle().fill(.black.opacity(0.25)).padding(5)
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: isReady && !showsCompletion ? 60 : 72)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .frame(width: 264, height: 100)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: title)
        .task(id: coordinator.lastInsertionID) {
            guard coordinator.lastInsertionID != nil else { return }
            showsCompletion = true
            do {
                try await Task.sleep(for: .milliseconds(500))
                showsCompletion = false
            } catch {
                // A new completion or removal cancels this timer.
            }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase != .idle { showsCompletion = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Whisper Dictation. \(title). \(detail)")
    }
}
