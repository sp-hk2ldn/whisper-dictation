import AppKit
@preconcurrency import AVFoundation
import Carbon
import Combine
import Foundation

private enum LegacyHotkeyPreset: String {
    case controlOptionCommandSpace
    case controlOptionD
    case controlOptionCommandD

    var chord: HotkeyChord {
        switch self {
        case .controlOptionCommandSpace:
            .pushToTalkDefault
        case .controlOptionD:
            HotkeyChord(
                keyCode: UInt32(kVK_ANSI_D),
                modifiers: UInt32(controlKey | optionKey)
            )
        case .controlOptionCommandD:
            HotkeyChord(
                keyCode: UInt32(kVK_ANSI_D),
                modifiers: UInt32(controlKey | optionKey | cmdKey)
            )
        }
    }
}

@MainActor
public final class DictationRuntime: ObservableObject {
    public enum ModelReadiness: Equatable {
        case notInstalled
        case loading
        case ready
        case failed
    }

    @Published public private(set) var lastError: String?
    @Published public private(set) var modelReadiness: ModelReadiness
    @Published public private(set) var hotkeyChord: HotkeyChord
    @Published public private(set) var accessibilityGranted: Bool
    @Published public private(set) var microphoneAuthorization: AVAuthorizationStatus

    public let coordinator: DictationSessionCoordinator
    public let microLighting: CodexMicroLighting
    private var microLightingSubscription: AnyCancellable?

    private let audio: any AudioCapturing
    private let transcriber: WhisperKitTranscriber
    private let insertion: MacTextInsertionService
    private let hotkey = CarbonHotkeySource()
    private let usesFixtureAudio: Bool
    private let runSmokeOnce: Bool
    private let smokeStatusURL: URL?

    private var hotkeyHeld = false
    private var beginTask: Task<UUID?, Never>?
    private var captureHandoff: Task<Void, Never>?

    public init() {
        let arguments = ProcessInfo.processInfo.arguments
        let deterministicSmoke = arguments.contains("--deterministic-smoke")
        let fixturePath = deterministicSmoke
            ? arguments
                .first(where: { $0.hasPrefix("--smoke-audio=") })?
                .dropFirst("--smoke-audio=".count)
                .description
            : nil
        let smokeStatusPath = deterministicSmoke
            ? arguments
                .first(where: { $0.hasPrefix("--smoke-status=") })?
                .dropFirst("--smoke-status=".count)
                .description
            : nil

        let audio: any AudioCapturing
        if let fixturePath {
            audio = FixtureAudioCapture(
                audioURL: URL(fileURLWithPath: fixturePath)
            )
            usesFixtureAudio = true
        } else {
            audio = AVAudioEngineCapture()
            usesFixtureAudio = false
        }

        let transcriber = WhisperKitTranscriber()
        let insertion = MacTextInsertionService()

        self.audio = audio
        self.transcriber = transcriber
        self.insertion = insertion
        runSmokeOnce = deterministicSmoke
            && arguments.contains("--smoke-run-once")
        smokeStatusURL = smokeStatusPath.map(URL.init(fileURLWithPath:))
        coordinator = DictationSessionCoordinator(
            audio: audio,
            transcriber: transcriber,
            targets: insertion,
            inserter: insertion,
            copyRecovery: { text in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }
        )

        let defaults = UserDefaults.standard
        if
            let keyCode = defaults.object(forKey: "hotkeyKeyCode")
                as? NSNumber,
            let modifiers = defaults.object(forKey: "hotkeyModifiers")
                as? NSNumber
        {
            hotkeyChord = HotkeyChord(
                keyCode: keyCode.uint32Value,
                modifiers: modifiers.uint32Value
            )
        } else {
            let legacyPreset = defaults.string(forKey: "hotkeyPreset")
                .flatMap(LegacyHotkeyPreset.init(rawValue:))
                ?? .controlOptionCommandSpace
            hotkeyChord = legacyPreset.chord
        }
        modelReadiness = WhisperModelConfiguration().isInstalled
            ? .ready
            : .notInstalled
        accessibilityGranted = insertion.isAccessibilityGranted
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        microLighting = CodexMicroLighting(
            enabled: !deterministicSmoke
                && (defaults.object(forKey: "codexMicroLightingEnabled") as? Bool ?? true),
            surface: defaults.string(forKey: CodexMicroLighting.surfaceKey)
                .flatMap(MicroSurface.init(rawValue:)) ?? .claudeApp
        )
        microLightingSubscription = coordinator.$phase.removeDuplicates().sink { [weak self] phase in
            self?.microLighting.show(phase)
        }
    }

    public func start() {
        refreshPermissions()
        microLighting.start()
        writeSmokeStatus(
            "launch accessibility=\(accessibilityGranted) "
                + "model=\(modelReadiness)"
        )
        do {
            try registerHotkey()
            lastError = nil
            if runSmokeOnce {
                runDeterministicSmokeOnce()
            }
            if ProcessInfo.processInfo.arguments.contains("--micro-lighting-check") {
                microLighting.runHardwareCheck()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stop() {
        microLightingSubscription = nil
        microLighting.stop()
        beginTask?.cancel()
        beginTask = nil
        hotkey.unregister()
        Task {
            await coordinator.cancelDictation()
        }
    }

    public func beginHotkeyCapture() {
        hotkey.unregister()
    }

    public func cancelHotkeyCapture() {
        do {
            try registerHotkey()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func setHotkeyChord(_ chord: HotkeyChord) {
        guard let validationMessage = chord.validationMessage else {
            applyHotkeyChord(chord)
            return
        }
        try? registerHotkey()
        lastError = validationMessage
    }

    private func applyHotkeyChord(_ chord: HotkeyChord) {
        let previous = hotkeyChord
        hotkeyChord = chord

        do {
            try registerHotkey()
            let defaults = UserDefaults.standard
            defaults.set(chord.keyCode, forKey: "hotkeyKeyCode")
            defaults.set(chord.modifiers, forKey: "hotkeyModifiers")
            defaults.removeObject(forKey: "hotkeyPreset")
            lastError = nil
        } catch {
            hotkeyChord = previous
            try? registerHotkey()
            lastError = error.localizedDescription
        }
    }

    public func requestAccessibility() {
        insertion.requestAccessibilityPermission()
        refreshPermissions()
    }

    public func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshPermissions()
        if !granted {
            lastError = "Microphone access is required for dictation."
        }
    }

    public func prepareModel() async {
        modelReadiness = .loading
        lastError = nil
        do {
            try await transcriber.prepare()
            modelReadiness = .ready
        } catch {
            modelReadiness = .failed
            lastError = error.localizedDescription
        }
    }

    public func cancel() async {
        hotkeyHeld = false
        beginTask?.cancel()
        beginTask = nil
        await coordinator.cancelDictation()
        lastError = nil
    }

    public func copyRecoveryText() {
        guard let text = coordinator.recoveryText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        coordinator.dismissOutcome()
        lastError = nil
    }

    public func dismissOutcome() {
        coordinator.dismissOutcome()
        lastError = nil
    }

    public func quit() {
        NSApp.terminate(nil)
    }

    public func stopMicroLighting(completion: @escaping @Sendable () -> Void) {
        microLightingSubscription = nil
        microLighting.stop(completion: completion)
    }

    public func refreshPermissions() {
        microLighting.refreshPermission()
        accessibilityGranted = insertion.isAccessibilityGranted
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func registerHotkey() throws {
        try hotkey.register(chord: hotkeyChord) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: PushToTalkEvent) {
        switch event {
        case .pressed:
            writeLastSessionDiagnostic("hotkey-pressed")
            hotkeyHeld = true
            let handoff = captureHandoff
            beginTask = Task { [weak self] in
                await handoff?.value
                guard !Task.isCancelled else { return nil }
                return await self?.beginAfterPermissions()
            }
        case .released:
            hotkeyHeld = false
            // Bind release to its own press, including a release that arrives
            // before microphone startup completes. Never stop a newer capture.
            let pressedTask = beginTask
            captureHandoff = Task { [weak self] in
                guard let id = await pressedTask?.value, let self,
                      let job = coordinator.enqueueRecording(sessionID: id) else { return }
                Task { [weak self] in
                    await job.value
                    await self?.recordCompletionDiagnostic()
                }
            }
        }
    }

    private func beginAfterPermissions() async -> UUID? {
        guard modelReadiness == .ready else {
            lastError = "Download the local model in Settings before dictating."
            return nil
        }

        refreshPermissions()
        guard await microphoneIsAuthorized() else {
            refreshPermissions()
            lastError = "Enable Microphone access in Settings before dictating."
            return nil
        }

        refreshPermissions()
        guard accessibilityGranted else {
            lastError = "Enable Accessibility for Whisper Dictation, then try again."
            return nil
        }

        UserDefaults.standard.removeObject(
            forKey: "lastInsertionDiagnostic"
        )
        lastError = nil
        guard !Task.isCancelled else { return nil }
        let id = await coordinator.beginDictation()
        if id == nil && !Task.isCancelled {
            lastError = "Please wait for the queued dictation to finish, then try again."
        }
        writeLastSessionDiagnostic("recording-began phase=\(coordinator.phase)")
        return id
    }

    private func finishRecording(sessionID: UUID? = nil) async {
        await coordinator.endDictation(sessionID: sessionID)
        await recordCompletionDiagnostic()
    }

    private func recordCompletionDiagnostic() async {
        let diagnostic = await insertion.diagnosticSummary()
        let failure = coordinator.failureDiagnostic.map {
            " failure=\($0)"
        } ?? ""
        writeLastSessionDiagnostic(
            "finished phase=\(coordinator.phase) insertion=\(diagnostic)"
                + failure
        )
        guard coordinator.phase == .needsRecovery else { return }
        UserDefaults.standard.set(
            diagnostic,
            forKey: "lastInsertionDiagnostic"
        )
        lastError = Self.insertionFailureMessage(for: diagnostic)
    }

    private static func insertionFailureMessage(for diagnostic: String) -> String {
        let reason: String
        if diagnostic.contains("frontmost-process-changed") {
            reason = "The frontmost app changed while Whisper was transcribing."
        } else if diagnostic.contains("no-focused-element") {
            reason = "The original app no longer reported a focused text field."
        } else if diagnostic.contains("focused-element-not-editable") {
            reason = "Focus moved to a control that cannot accept text."
        } else if diagnostic.contains("target-fingerprint-changed") {
            reason = "Focus moved to a different field or window."
        } else if diagnostic.contains("accessibility-denied") {
            reason = "macOS revoked Accessibility access."
        } else if diagnostic.contains("capture no-eligible-focused-element") {
            reason = "No editable text field was focused when recording began."
        } else {
            reason = "The original insertion target could not be validated safely."
        }

        return "\(reason) No text was inserted. [\(diagnostic)]"
    }

    private func writeLastSessionDiagnostic(_ diagnostic: String) {
        let defaults = UserDefaults.standard
        defaults.set(
            diagnostic,
            forKey: "lastDictationSessionDiagnostic"
        )
        var history = defaults.stringArray(
            forKey: "dictationSessionDiagnosticHistory"
        ) ?? []
        history.append(diagnostic)
        if history.count > 20 {
            history.removeFirst(history.count - 20)
        }
        defaults.set(
            history,
            forKey: "dictationSessionDiagnosticHistory"
        )
    }

    private func microphoneIsAuthorized() async -> Bool {
        if usesFixtureAudio {
            return true
        }

        return switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined, .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private func runDeterministicSmokeOnce() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self else { return }

            hotkeyHeld = true
            _ = await beginAfterPermissions()
            hotkeyHeld = false
            if coordinator.phase == .recording {
                await finishRecording()
            }
            let insertionDiagnostic = await insertion.diagnosticSummary()
            writeSmokeStatus(
                "final accessibility=\(accessibilityGranted) "
                    + "model=\(modelReadiness) "
                    + "phase=\(coordinator.phase) "
                    + "recovery=\(coordinator.recoveryText == nil ? "none" : "present") "
                    + "insertion=\(insertionDiagnostic)"
            )
        }
    }

    private func writeSmokeStatus(_ status: String) {
        guard let smokeStatusURL else { return }
        try? status.write(
            to: smokeStatusURL,
            atomically: true,
            encoding: .utf8
        )
    }
}
