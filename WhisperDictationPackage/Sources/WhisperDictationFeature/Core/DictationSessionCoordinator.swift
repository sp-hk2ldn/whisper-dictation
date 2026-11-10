import Combine
import Foundation

@MainActor
public final class DictationSessionCoordinator: ObservableObject {
    public enum Phase: Sendable, Equatable {
        case idle, recording, transcribing, inserting, needsRecovery, failed
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastInsertionID: UUID?
    @Published public private(set) var recoveryCopied = false
    @Published public private(set) var recoveryText: String?
    @Published public private(set) var failureDiagnostic: String?
    @Published public private(set) var pendingCount = 0

    private let copyRecovery: @MainActor (String) -> Bool
    private let audio: any AudioCapturing
    private let transcriber: any Transcribing
    private let targets: any TargetTracking
    private let inserter: any TextInserting
    private var recordingID: UUID?
    private var recordingStarted = false
    private var recordingTarget: TargetToken?
    private var liveSessions = Set<UUID>()
    private var processingPhase: Phase?
    // The microphone is released before processing starts. These two fences
    // serialize microphone stop/start and model/clipboard work independently.
    private var captureStop: Task<CapturedUtterance, Error>?
    private var processingTail: Task<Void, Never>?
    private var hasFailure = false

    public init(audio: any AudioCapturing, transcriber: any Transcribing,
                targets: any TargetTracking, inserter: any TextInserting,
                copyRecovery: @escaping @MainActor (String) -> Bool = { _ in false }) {
        self.copyRecovery = copyRecovery
        self.audio = audio
        self.transcriber = transcriber
        self.targets = targets
        self.inserter = inserter
    }

    @discardableResult
    public func beginDictation() async -> UUID? {
        guard recordingID == nil, liveSessions.count < 4 else { return nil }
        if liveSessions.isEmpty {
            hasFailure = false
            failureDiagnostic = nil
        }
        let id = UUID()
        recordingID = id
        liveSessions.insert(id)
        // A rapid press can arrive while the previous buffer is being frozen.
        if let captureStop { _ = try? await captureStop.value }
        guard liveSessions.contains(id) else { return nil }
        // Start the microphone concurrently with the target lookup so AX
        // latency cannot clip the beginning of an immediately spoken phrase.
        let start = Task { try await audio.start(sessionID: id) }
        let target = await targets.captureTarget()
        guard liveSessions.contains(id) else {
            _ = try? await start.value
            await audio.cancel(sessionID: id)
            if let target { await targets.releaseTarget(target) }
            return nil
        }
        recordingTarget = target
        do {
            try await start.value
            guard liveSessions.contains(id) else {
                await audio.cancel(sessionID: id)
                if let target { await targets.releaseTarget(target) }
                return nil
            }
            recordingStarted = true
            refreshPhase()
            return id
        } catch {
            if liveSessions.contains(id) {
                recordingID = nil
                recordingStarted = false
                recordingTarget = nil
                liveSessions.remove(id)
                hasFailure = true
                failureDiagnostic = "audio-start \(String(reflecting: error))"
                refreshPhase()
            }
            if let target { await targets.releaseTarget(target) }
            return nil
        }
    }

    public func endDictation(sessionID expectedID: UUID? = nil) async {
        await enqueueRecording(sessionID: expectedID)?.value
    }

    /// Free the microphone lane immediately; callers may await the returned
    /// processing task without preventing another shortcut press.
    func enqueueRecording(sessionID expectedID: UUID? = nil) -> Task<Void, Never>? {
        guard let id = recordingID, expectedID == nil || expectedID == id else { return nil }
        let target = recordingTarget
        recordingID = nil
        recordingStarted = false
        recordingTarget = nil
        pendingCount += 1
        let stop = Task { try await audio.stop(sessionID: id) }
        captureStop = stop
        let predecessor = processingTail
        let job = Task { [self] in
            // No concurrent Whisper inference or clipboard transactions, even
            // when a new microphone capture overlaps the preceding insertion.
            await predecessor?.value
            guard liveSessions.contains(id) else {
                if let target { await targets.releaseTarget(target) }
                return
            }
            await process(id: id, target: target, stop: stop)
            if let target { await targets.releaseTarget(target) }
        }
        processingTail = job
        refreshPhase()
        return job
    }

    private func process(id: UUID, target: TargetToken?, stop: Task<CapturedUtterance, Error>) async {
        processingPhase = .transcribing
        refreshPhase()
        var stage = "audio-stop"
        var audioSummary = ""
        do {
            let utterance = try await stop.value
            guard liveSessions.contains(id) else { return }
            let peak = utterance.samples.reduce(Float.zero) { max($0, abs($1)) }
            audioSummary = String(format: " duration=%.3fs peak=%.4f", utterance.duration, peak)
            if utterance.duration >= 0.1 {
                stage = "transcription"
                let transcript = try await transcriber.transcribeFinal(utterance, sessionID: id)
                guard liveSessions.contains(id) else { return }
                if let target, let text = TranscriptPolicy.safeText(from: transcript, for: target) {
                    let valid = await targets.isStillValid(target)
                    guard liveSessions.contains(id) else { return }
                    if valid {
                        processingPhase = .inserting
                        refreshPhase()
                        let result = await inserter.insert(text, into: target, sessionID: id)
                        guard liveSessions.contains(id) else { return }
                        if result == .inserted { lastInsertionID = id }
                        else { recover(text.value) }
                    } else { recover(text.value) }
                } else { recover(transcript.text) }
            }
        } catch {
            if liveSessions.contains(id) {
                hasFailure = true
                failureDiagnostic = "\(stage) \(String(reflecting: error))\(audioSummary)"
            }
        }
        guard liveSessions.remove(id) != nil else { return }
        pendingCount -= 1
        if liveSessions.isEmpty { await audio.finishBatch() }
        processingPhase = nil
        refreshPhase()
    }

    private func recover(_ text: String) {
        recoveryText = [recoveryText, text].compactMap { $0 }.joined(separator: "\n\n")
        recoveryCopied = copyRecovery(text)
    }

    public func cancelDictation() async {
        let ids = liveSessions
        let target = recordingTarget
        liveSessions.removeAll()
        recordingID = nil
        recordingStarted = false
        recordingTarget = nil
        pendingCount = 0
        processingPhase = nil
        failureDiagnostic = nil
        hasFailure = false
        refreshPhase()
        // Keep the processing fence: an already-posted paste must restore its
        // clipboard before any later insertion can begin.
        for id in ids {
            await audio.cancel(sessionID: id)
            await transcriber.cancel(sessionID: id)
        }
        if let target { await targets.releaseTarget(target) }
        await audio.finishBatch()
    }

    public func dismissOutcome() {
        recoveryCopied = false
        recoveryText = nil
        failureDiagnostic = nil
        hasFailure = false
        refreshPhase()
    }

    private func refreshPhase() {
        if recordingStarted { phase = .recording }
        else if let processingPhase { phase = processingPhase }
        else if pendingCount > 0 { phase = .transcribing }
        else if recoveryText != nil { phase = .needsRecovery }
        else if hasFailure { phase = .failed }
        else { phase = .idle }
    }
}
