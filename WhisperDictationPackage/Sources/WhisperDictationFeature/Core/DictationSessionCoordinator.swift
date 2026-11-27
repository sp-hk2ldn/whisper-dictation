//
//  DictationSessionCoordinator.swift
//  WhisperDictation
//
//  Created by Stephen Parker on 27/11/2026.
//

import Combine
import Foundation

@MainActor
public final class DictationSessionCoordinator: ObservableObject {
    public enum Phase: Sendable, Equatable {
        case idle, recording, transcribing, inserting, needsRecovery, failed
    }

    struct SessionTimings: Sendable {
        let audioDuration: TimeInterval?
        let modelLoadDuration: Duration?
        let transcriptionDuration: Duration?
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastInsertionID: UUID?
    @Published public private(set) var recoveryCopied = false
    @Published public private(set) var recoveryText: String?
    @Published public private(set) var failureDiagnostic: String?
    @Published public private(set) var pendingCount = 0

    private let copyRecovery: @MainActor (String) -> Bool
    private let record: @MainActor (UUID, String) -> Void
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
    private var processingTail: Task<SessionTimings?, Never>?
    private var hasFailure = false

    public init(
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        targets: any TargetTracking,
        inserter: any TextInserting,
        copyRecovery: @escaping @MainActor (String) -> Bool = { _ in false },
        record: @escaping @MainActor (UUID, String) -> Void = { _, _ in }
    ) {
        self.copyRecovery = copyRecovery
        self.record = record
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
        _ = await enqueueRecording(sessionID: expectedID)?.value
    }

    /// Free the microphone lane immediately; callers may await the returned
    /// processing task without preventing another shortcut press.
    func enqueueRecording(sessionID expectedID: UUID? = nil) -> Task<SessionTimings?, Never>? {
        guard let id = recordingID, expectedID == nil || expectedID == id else { return nil }
        let target = recordingTarget
        recordingID = nil
        recordingStarted = false
        recordingTarget = nil
        pendingCount += 1
        let stop = Task { try await audio.stop(sessionID: id) }
        captureStop = stop
        let predecessor = processingTail
        let job = Task { [self] () -> SessionTimings? in
            // No concurrent Whisper inference or clipboard transactions, even
            // when a new microphone capture overlaps the preceding insertion.
            _ = await predecessor?.value
            guard liveSessions.contains(id) else {
                if let target { await targets.releaseTarget(target) }
                return nil
            }
            let timings = await process(
                id: id,
                target: target,
                stop: stop
            )
            if let target { await targets.releaseTarget(target) }
            return timings
        }
        processingTail = job
        refreshPhase()
        return job
    }

    private func process(
        id: UUID,
        target: TargetToken?,
        stop: Task<CapturedUtterance, Error>
    ) async -> SessionTimings? {
        processingPhase = .transcribing
        refreshPhase()
        var stage = "audio-stop"
        var audioSummary = ""
        var audioDuration: TimeInterval?
        var finalTranscript: FinalTranscript?
        do {
            let utterance = try await stop.value
            guard liveSessions.contains(id) else { return nil }
            let duration = utterance.duration
            audioDuration = duration
            let peak = utterance.samples.reduce(Float.zero) { max($0, abs($1)) }
            audioSummary = String(
                format: " duration=%.3fs peak=%.4f",
                duration,
                peak
            )
            if duration >= 0.1 {
                stage = "transcription"
                finalTranscript = try await transcribeAndInsert(
                    utterance,
                    into: target,
                    sessionID: id
                )
            }
        } catch {
            if liveSessions.contains(id) {
                hasFailure = true
                failureDiagnostic = "\(stage) \(String(reflecting: error))\(audioSummary)"
            }
        }
        let timings = SessionTimings(
            audioDuration: audioDuration,
            modelLoadDuration: finalTranscript?.modelLoadDuration,
            transcriptionDuration: finalTranscript?.transcriptionDuration
        )
        guard liveSessions.remove(id) != nil else { return timings }
        pendingCount -= 1
        if liveSessions.isEmpty { await audio.finishBatch() }
        processingPhase = nil
        refreshPhase()
        return timings
    }

    private func transcribeAndInsert(
        _ utterance: CapturedUtterance,
        into target: TargetToken?,
        sessionID: UUID
    ) async throws -> FinalTranscript {
        let transcript = try await transcriber.transcribeFinal(utterance, sessionID: sessionID)
        if !transcript.text.isEmpty {
            record(sessionID, transcript.text)
        }
        await insert(
            transcript,
            into: target,
            sessionID: sessionID
        )
        return transcript
    }

    private func insert(
        _ transcript: FinalTranscript,
        into target: TargetToken?,
        sessionID: UUID
    ) async {
        guard liveSessions.contains(sessionID) else { return }
        guard
            let target,
            let text = TranscriptPolicy.safeText(from: transcript, for: target)
        else {
            recover(transcript.text)
            return
        }

        let valid = await targets.isStillValid(target)
        guard liveSessions.contains(sessionID) else { return }
        guard valid else {
            recover(text.value)
            return
        }

        processingPhase = .inserting
        refreshPhase()
        let result = await inserter.insert(
            text,
            into: target,
            sessionID: sessionID
        )
        guard liveSessions.contains(sessionID) else { return }
        guard result == .inserted else {
            recover(text.value)
            return
        }
        lastInsertionID = sessionID
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
