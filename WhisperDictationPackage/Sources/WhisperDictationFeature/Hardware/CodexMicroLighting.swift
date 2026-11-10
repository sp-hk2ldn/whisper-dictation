import AppKit
import Combine
import IOKit.hidsystem

@MainActor
public final class CodexMicroLighting: ObservableObject {
    private static let completedHold: Duration = .milliseconds(450)
    private static let highlightExpiryMargin: TimeInterval = 0.05
    private static let inactivityLimit: Duration = .seconds(600)
    private static let joystickLogInterval: TimeInterval = 0.25
    private static let inputDiagnosticKey = "codexMicroInputDiagnostic"
    static let surfaceKey = "codexMicroSurface"

    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "codexMicroLightingEnabled")
            guard isEnabled != oldValue else { return }
            if isEnabled {
                start()
            } else {
                pause()
            }
        }
    }
    @Published public var surface: MicroSurface {
        didSet {
            UserDefaults.standard.set(surface.rawValue, forKey: Self.surfaceKey)
            guard surface != oldValue, isEnabled else { return }
            switchSurface(from: oldValue)
        }
    }
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var needsPermission = false

    private var phase: DictationSessionCoordinator.Phase = .idle
    private var voice = MicroVoiceLight.idle
    private var board = ClaudeSlotBoard.empty
    private var records: [ClaudeSessionRecord] = []
    private var desktop = ClaudeDesktopIndex.empty
    private var isDormant = false
    private var generation = 0
    private var highlightTask: Task<Void, Never>?
    private var inactivityTask: Task<Void, Never>?
    private var inputLog: MicroInputDiagnosticLog
    private var lastJoystickLoggedAt = Date.distantPast
    private let store: ClaudeSessionStore
    private let desktopStore: ClaudeDesktopSessionStore
    private let actions: ClaudeMicroActions
    private let assigner = ClaudeSlotAssigner()
    private let builder = MicroPictureBuilder()
    private lazy var transport = CodexMicroTransport { [weak self] event in
        Task { @MainActor in self?.receive(event) }
    }
    private lazy var watcher = ClaudeSessionWatcher(store: store) { [weak self] records in
        Task { @MainActor in self?.sessionsChanged(records) }
    }
    private lazy var desktopWatcher = ClaudeDesktopWatcher(store: desktopStore) { [weak self] index in
        Task { @MainActor in self?.desktopChanged(index) }
    }

    init(
        enabled: Bool,
        surface: MicroSurface = .claudeApp,
        store: ClaudeSessionStore = ClaudeSessionStore(
            directory: ClaudeSessionStore.defaultDirectory
        ),
        desktopStore: ClaudeDesktopSessionStore = ClaudeDesktopSessionStore(
            root: ClaudeDesktopSessionStore.defaultRoot
        ),
        claudeApp: ClaudeAppControlling = SystemClaudeApp()
    ) {
        isEnabled = enabled
        self.surface = surface
        self.store = store
        self.desktopStore = desktopStore
        actions = ClaudeMicroActions(
            app: claudeApp,
            desktopStore: desktopStore
        )
        inputLog = MicroInputDiagnosticLog(
            lines: UserDefaults.standard.stringArray(forKey: Self.inputDiagnosticKey) ?? []
        )
    }

    func start() {
        guard isEnabled else { return }
        guard surface.host != nil else {
            statusMessage = Self.codexMessage
            return
        }
        transport.start()
        watcher.start()
        desktopWatcher.start()
        noteActivity()
        render()
    }

    func show(_ phase: DictationSessionCoordinator.Phase) {
        let wasInserting = self.phase == .inserting
        self.phase = phase
        generation += 1
        let nextVoice: MicroVoiceLight = switch phase {
        case .recording: .recording
        case .transcribing, .inserting: .processing
        case .idle: wasInserting ? .completed : .idle
        case .needsRecovery, .failed: .idle
        }
        voice = nextVoice
        guard isEnabled else { return }
        noteActivity()
        render()
        guard nextVoice == .completed else { return }
        let expected = generation
        Task { [weak self] in
            try? await Task.sleep(for: Self.completedHold)
            guard let self, generation == expected else { return }
            voice = .idle
            render()
        }
    }

    public func requestPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func runHardwareCheck() {
        guard isEnabled, phase == .idle else { return }
        generation += 1
        let expected = generation
        let sequence: [MicroVoiceLight] = [.recording, .processing, .completed, .idle]
        sequence.enumerated().forEach { index, light in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(index))
                guard let self, generation == expected else { return }
                voice = light
                render()
            }
        }
    }

    func refreshPermission() {
        guard needsPermission, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        needsPermission = false
        statusMessage = nil
        transport.reconnect()
    }

    func stop(completion: @escaping @Sendable () -> Void = {}) {
        generation += 1
        cancelTimers()
        watcher.stop()
        desktopWatcher.stop()
        transport.stop(completion: completion)
    }

    private static let codexMessage = "Codex controls the Micro. Whisper is not sending lights or reading keys."

    private func switchSurface(from previous: MicroSurface) {
        guard surface.host != nil else {
            pause(.leaveLights)
            statusMessage = Self.codexMessage
            return
        }
        guard previous.host != nil else {
            statusMessage = nil
            start()
            return
        }
        board = assigner.applying(
            visibleRecords,
            to: .empty,
            focusedSessionID: desktop.focusedCLISessionID,
            now: Date()
        )
        noteActivity()
        render()
    }

    private var visibleRecords: [ClaudeSessionRecord] {
        records.filter { $0.host == surface.host }
    }

    private func pause(_ ending: CodexMicroTransport.Ending = .clearLights) {
        generation += 1
        cancelTimers()
        watcher.stop()
        desktopWatcher.stop()
        transport.stop(ending) {}
        if voice == .completed { voice = .idle }
        board = .empty
        records = []
        desktop = .empty
        statusMessage = nil
        needsPermission = false
    }

    private func cancelTimers() {
        highlightTask?.cancel()
        inactivityTask?.cancel()
    }

    private func render() {
        guard isEnabled, surface.host != nil else { return }
        let now = Date()
        let picture = isDormant
            ? MicroPicture.allOff
            : builder.picture(
                board: board,
                voice: voice,
                now: now
            )
        transport.show(picture)
        scheduleHighlightExpiry(now: now)
    }

    private func scheduleHighlightExpiry(now: Date) {
        highlightTask?.cancel()
        guard let changedAt = board.selectionChangedAt else { return }
        let remaining = changedAt
            .addingTimeInterval(MicroPictureBuilder.highlightDuration)
            .timeIntervalSince(now)
        guard remaining > 0 else { return }
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining + Self.highlightExpiryMargin))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    private func noteActivity() {
        isDormant = false
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: Self.inactivityLimit)
            guard !Task.isCancelled else { return }
            self?.goDormant()
        }
    }

    private func goDormant() {
        isDormant = true
        render()
    }

    private func sessionsChanged(_ records: [ClaudeSessionRecord]) {
        guard isEnabled, surface.host != nil else { return }
        self.records = records
        board = assigner.applying(
            visibleRecords,
            to: board,
            focusedSessionID: desktop.focusedCLISessionID,
            now: Date()
        )
        noteActivity()
        render()
    }

    private func desktopChanged(_ index: ClaudeDesktopIndex) {
        guard isEnabled, surface.host != nil else { return }
        let focusChanged = index.focusedCLISessionID != desktop.focusedCLISessionID
        desktop = index
        guard focusChanged else { return }
        board = assigner.applying(
            visibleRecords,
            to: board,
            focusedSessionID: index.focusedCLISessionID,
            now: Date()
        )
        noteActivity()
        render()
    }

    private func receive(_ event: MicroTransportEvent) {
        guard isEnabled, surface.host != nil else { return }
        switch event {
        case .status(let error): report(error)
        case .input(let input): handle(input)
        }
    }

    private func report(_ error: MicroLightingError?) {
        needsPermission = error == .permissionDenied
        statusMessage = error?.message
        UserDefaults.standard.set(
            "\(Date().ISO8601Format()) \(error?.message ?? "connected")",
            forKey: "codexMicroLightingDiagnostic"
        )
    }

    private func handle(_ input: MicroInput) {
        record(input)
        if case .key = input {
            noteActivity()
            render()
        }
        guard let press = MicroPress(input), let host = surface.host else { return }
        let outcome = actions.perform(
            press,
            on: board,
            host: host,
            index: desktop
        )
        desktop = outcome.index
        record(action: outcome.log)
        guard let slot = outcome.openedSlot else { return }
        board = assigner.pressing(
            slot: slot,
            on: board,
            now: Date()
        )
        render()
    }

    private func record(action: String) {
        inputLog = inputLog.appending(action: action, at: Date())
        saveInputLog()
    }

    private func saveInputLog() {
        UserDefaults.standard.set(inputLog.lines, forKey: Self.inputDiagnosticKey)
    }

    private func record(_ input: MicroInput) {
        let now = Date()
        if case .joystick = input {
            guard now.timeIntervalSince(lastJoystickLoggedAt) >= Self.joystickLogInterval else {
                return
            }
            lastJoystickLoggedAt = now
        }
        inputLog = inputLog.appending(input, at: now)
        saveInputLog()
    }
}
