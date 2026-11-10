import AppKit
import SwiftUI
import WhisperDictationFeature

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = DictationRuntime()
    private var settingsWindowController: NSWindowController?
    private var floatingStatusController: FloatingDictationStatusController?
    private var awaitingLightingShutdown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        floatingStatusController = FloatingDictationStatusController(runtime: runtime)
        runtime.start()
        runSettingsWindowSmokeIfRequested()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !awaitingLightingShutdown else { return .terminateLater }
        awaitingLightingShutdown = true
        runtime.stopMicroLighting { [weak self] in
            DispatchQueue.main.async { self?.finishTermination() }
        }
        // A disconnected or unresponsive accessory must not hold the app open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard awaitingLightingShutdown else { return }
        awaitingLightingShutdown = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func showSettingsWindow() {
        if let settingsWindowController {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let contentSize = NSSize(width: 480, height: 440)
        let hostingController = NSHostingController(
            rootView: DictationSettingsView(runtime: runtime)
                .frame(
                    width: contentSize.width,
                    height: contentSize.height
                )
        )
        hostingController.sizingOptions = []
        hostingController.view.frame = NSRect(
            origin: .zero,
            size: contentSize
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: contentSize.width,
                height: contentSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Dictation Settings"
        window.contentViewController = hostingController
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()

        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func runSettingsWindowSmokeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            arguments.contains("--deterministic-smoke"),
            let path = arguments
                .first(where: {
                    $0.hasPrefix("--smoke-settings-status=")
                })?
                .dropFirst("--smoke-settings-status=".count)
                .description
        else {
            return
        }

        showSettingsWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            [weak self] in
            let window = self?.settingsWindowController?.window
            let contentSize = window?.contentView?.bounds.size ?? .zero
            let hostedSize = window?.contentViewController?.view.bounds.size
                ?? .zero
            let ready = window?.isVisible == true
                && window?.isKeyWindow == true
                && contentSize.width >= 480
                && contentSize.height >= 440
                && hostedSize.width >= 480
                && hostedSize.height >= 440
            let status = "ready=\(ready) "
                + "visible=\(window?.isVisible == true) "
                + "key=\(window?.isKeyWindow == true) "
                + "content=\(Int(contentSize.width))x"
                + "\(Int(contentSize.height)) "
                + "hosted=\(Int(hostedSize.width))x"
                + "\(Int(hostedSize.height))"
            try? status.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}

@main
struct WhisperDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DictationMenuContent(
                runtime: appDelegate.runtime,
                openSettings: {
                    appDelegate.showSettingsWindow()
                }
            )
        } label: {
            DictationMenuLabel(coordinator: appDelegate.runtime.coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct DictationMenuContent: View {
    @ObservedObject var runtime: DictationRuntime
    @ObservedObject var coordinator: DictationSessionCoordinator
    let openSettings: @MainActor () -> Void

    init(
        runtime: DictationRuntime,
        openSettings: @escaping @MainActor () -> Void
    ) {
        self.runtime = runtime
        coordinator = runtime.coordinator
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            DictationMenuPopoverContent(
                phase: coordinator.phase,
                recoveryText: coordinator.recoveryText,
                actions: DictationUIActions(
                    cancel: { await runtime.cancel() },
                    copyRecoveryText: { runtime.copyRecoveryText() },
                    dismissOutcome: { runtime.dismissOutcome() },
                    openSettings: { openSettings() },
                    quit: { runtime.quit() }
                )
            )

            MicroLightingControls(lighting: runtime.microLighting)

            if let error = runtime.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: 300, alignment: .leading)
            }
        }
    }
}

private struct MicroLightingControls: View {
    @ObservedObject var lighting: CodexMicroLighting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Toggle("Codex Micro lighting", isOn: $lighting.isEnabled)
            if lighting.isEnabled {
                Picker("Micro controls", selection: $lighting.surface) {
                    ForEach(MicroSurface.allCases) { surface in
                        Text(surface.title).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Micro controls")
            }
            if lighting.isEnabled, let message = lighting.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                if lighting.needsPermission {
                    Button("Enable Input Monitoring…") { lighting.requestPermission() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 300)
    }
}

private struct DictationMenuLabel: View {
    @ObservedObject var coordinator: DictationSessionCoordinator

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch coordinator.phase {
        case .idle:
            "mic"
        case .recording:
            "record.circle.fill"
        case .transcribing:
            "waveform"
        case .inserting:
            "text.cursor"
        case .needsRecovery:
            "exclamationmark.triangle"
        case .failed:
            "xmark.circle"
        }
    }

    private var accessibilityLabel: String {
        "Whisper Dictation: \(String(describing: coordinator.phase))"
    }
}
