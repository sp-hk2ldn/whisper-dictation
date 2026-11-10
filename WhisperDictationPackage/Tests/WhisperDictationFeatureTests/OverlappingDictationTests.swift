import Foundation
import Testing
@testable import WhisperDictationFeature

@MainActor
struct OverlappingDictationTests {
    @Test func recordsDuringInsertionAndPreservesOrder() async {
        let rig = OverlapRig()
        await rig.coordinator.beginDictation()
        let first = rig.coordinator.enqueueRecording()!
        await rig.inserter.entered.wait()

        let nextID = await rig.coordinator.beginDictation()
        #expect(nextID != nil)
        #expect(rig.coordinator.phase == .recording)
        #expect(await rig.audio.starts == 2)
        let second = rig.coordinator.enqueueRecording(sessionID: nextID)!
        #expect(await rig.transcriber.calls == 1)
        await rig.inserter.proceed.open()
        await first.value
        await second.value

        #expect(await rig.inserter.texts == ["phrase 1", "phrase 2"])
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.pendingCount == 0)
        #expect(await rig.targets.retainedCount == 0)
    }

    @Test func cancellationDiscardsQueuedAudioAndAllowsFreshCapture() async {
        let rig = OverlapRig()
        await rig.coordinator.beginDictation()
        let first = rig.coordinator.enqueueRecording()!
        await rig.inserter.entered.wait()
        await rig.coordinator.beginDictation()
        let second = rig.coordinator.enqueueRecording()!
        await rig.coordinator.cancelDictation()
        let freshID = await rig.coordinator.beginDictation()
        #expect(freshID != nil)
        await rig.inserter.proceed.open()
        await first.value
        await second.value
        #expect(rig.coordinator.phase == .recording)
        #expect(await rig.transcriber.calls == 1)
        await rig.coordinator.endDictation(sessionID: freshID)
        #expect(await rig.inserter.texts == ["phrase 1", "phrase 2"])
        #expect(rig.coordinator.phase == .idle)
        #expect(await rig.targets.retainedCount == 0)
    }

    @Test func queueIsBoundedAndChangedTargetRecoversNextTranscript() async {
        let rig = OverlapRig()
        await rig.coordinator.beginDictation()
        let first = rig.coordinator.enqueueRecording()!
        await rig.inserter.entered.wait()
        var queued: [Task<Void, Never>] = []
        for _ in 0..<3 {
            #expect(await rig.coordinator.beginDictation() != nil)
            queued.append(rig.coordinator.enqueueRecording()!)
        }
        #expect(await rig.coordinator.beginDictation() == nil)
        await rig.targets.invalidate()
        await rig.inserter.proceed.open()
        await first.value
        for task in queued { await task.value }
        #expect(await rig.inserter.texts == ["phrase 1"])
        #expect(rig.coordinator.recoveryText == "phrase 2\n\nphrase 3\n\nphrase 4")
        #expect(rig.coordinator.phase == .needsRecovery)
        #expect(await rig.targets.retainedCount == 0)
    }
}

@MainActor
private struct OverlapRig {
    let audio = OverlapAudio()
    let transcriber = NumberedTranscriber()
    let targets = RetainedTargets()
    let inserter = GatedInserter()
    let coordinator: DictationSessionCoordinator

    init() {
        coordinator = DictationSessionCoordinator(audio: audio, transcriber: transcriber,
                                                  targets: targets, inserter: inserter)
    }
}

private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor OverlapAudio: AudioCapturing {
    private var active: UUID?
    private(set) var starts = 0
    func start(sessionID: UUID) async throws {
        #expect(active == nil)
        active = sessionID
        starts += 1
    }
    func stop(sessionID: UUID) async throws -> CapturedUtterance {
        guard active == sessionID else { throw AudioCaptureError.notRecording }
        active = nil
        return CapturedUtterance(samples: Array(repeating: 0.1, count: 1600), sampleRate: 16000)
    }
    func cancel(sessionID: UUID) async {
        if active == sessionID { active = nil }
    }
}

private actor NumberedTranscriber: Transcribing {
    private(set) var calls = 0
    func transcribeFinal(_ utterance: CapturedUtterance, sessionID: UUID) async throws -> FinalTranscript {
        calls += 1
        return FinalTranscript(text: "phrase \(calls)")
    }
    func cancel(sessionID: UUID) async {}
}

private actor RetainedTargets: TargetTracking {
    private var retained = Set<UUID>()
    private var valid = true
    var retainedCount: Int { retained.count }
    func captureTarget() async -> TargetToken? {
        let token = TargetToken(kind: .standard)
        retained.insert(token.id)
        return token
    }
    func isStillValid(_ token: TargetToken) async -> Bool { valid && retained.contains(token.id) }
    func releaseTarget(_ token: TargetToken) async { retained.remove(token.id) }
    func invalidate() { valid = false }
}

private actor GatedInserter: TextInserting {
    let entered = Latch()
    let proceed = Latch()
    private(set) var texts: [String] = []
    func insert(_ text: SafeInsertionText, into target: TargetToken, sessionID: UUID) async -> InsertionResult {
        texts.append(text.value)
        if texts.count == 1 {
            await entered.open()
            await proceed.wait()
        }
        return .inserted
    }
}
