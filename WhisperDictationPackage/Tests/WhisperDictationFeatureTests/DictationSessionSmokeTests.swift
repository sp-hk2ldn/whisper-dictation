import Foundation
import Testing
@testable import WhisperDictationFeature

@MainActor
struct DictationSessionSmokeTests {
    @Test
    func recoveryIsCopiedAndSurvivesAnotherRecordingUntilDismissed() async {
        var clipboard = "original"
        let coordinator = DictationSessionCoordinator(
            audio: AudioFake(), transcriber: TranscriberFake(text: "keep this"),
            targets: TargetFake(valid: false), inserter: InsertionFake(),
            copyRecovery: { clipboard = $0; return true }
        )
        await coordinator.beginDictation()
        await coordinator.endDictation()
        #expect(clipboard == "keep this")
        #expect(coordinator.recoveryCopied)
        await coordinator.beginDictation()
        await coordinator.cancelDictation()
        #expect(coordinator.recoveryText == "keep this")
        #expect(coordinator.phase == .needsRecovery)
        await coordinator.beginDictation()
        await coordinator.endDictation()
        #expect(clipboard == "keep this")
        #expect(coordinator.recoveryText == "keep this\n\nkeep this")
        coordinator.dismissOutcome()
        #expect(coordinator.recoveryText == nil)
        #expect(clipboard == "keep this")
    }

    @Test
    func finalTranscriptIsInsertedExactlyOnce() async {
        let audio = AudioFake()
        let transcriber = TranscriberFake(text: "hello world")
        let targets = TargetFake(valid: true)
        let inserter = InsertionFake()
        let coordinator = DictationSessionCoordinator(
            audio: audio,
            transcriber: transcriber,
            targets: targets,
            inserter: inserter
        )

        await coordinator.beginDictation()
        await coordinator.endDictation()
        await coordinator.endDictation()

        #expect(coordinator.phase == .idle)
        #expect(await inserter.insertions == ["hello world"])
        #expect(coordinator.lastInsertionID != nil)
    }

    @Test
    func changedFocusRefusesInsertionAndPreservesTranscript() async {
        let inserter = InsertionFake()
        let coordinator = DictationSessionCoordinator(
            audio: AudioFake(),
            transcriber: TranscriberFake(text: "keep this"),
            targets: TargetFake(valid: false),
            inserter: inserter
        )

        await coordinator.beginDictation()
        await coordinator.endDictation()

        #expect(coordinator.phase == .needsRecovery)
        #expect(coordinator.recoveryText == "keep this")
        #expect(await inserter.insertions.isEmpty)
        #expect(coordinator.lastInsertionID == nil)
    }

    @Test
    func pressingAgainAfterRecoveryStartsTheNextRecording() async {
        let coordinator = DictationSessionCoordinator(
            audio: AudioFake(),
            transcriber: TranscriberFake(text: "keep this"),
            targets: TargetFake(valid: false),
            inserter: InsertionFake()
        )

        await coordinator.beginDictation()
        await coordinator.endDictation()

        await coordinator.beginDictation()

        #expect(coordinator.phase == .recording)
        #expect(coordinator.recoveryText == "keep this")
    }

    @Test
    func pressingAgainAfterFailureStartsTheNextRecording() async {
        let coordinator = DictationSessionCoordinator(
            audio: AudioFake(),
            transcriber: FailsOnceTranscriberFake(),
            targets: TargetFake(valid: true),
            inserter: InsertionFake()
        )

        await coordinator.beginDictation()
        await coordinator.endDictation()

        #expect(coordinator.phase == .failed)
        #expect(
            coordinator.failureDiagnostic?
                .hasPrefix("transcription ") == true
        )

        await coordinator.beginDictation()

        #expect(coordinator.phase == .recording)
        #expect(coordinator.failureDiagnostic == nil)
    }

    @Test
    func cancellationPreventsInsertion() async {
        let inserter = InsertionFake()
        let coordinator = DictationSessionCoordinator(
            audio: AudioFake(),
            transcriber: TranscriberFake(text: "do not insert"),
            targets: TargetFake(valid: true),
            inserter: inserter
        )

        await coordinator.beginDictation()
        await coordinator.cancelDictation()
        await coordinator.endDictation()

        #expect(coordinator.phase == .idle)
        #expect(await inserter.insertions.isEmpty)
        #expect(coordinator.lastInsertionID == nil)
    }

    @Test
    func terminalTextCannotContainSubmitCharacters() {
        let token = TargetToken(kind: .terminal)
        let transcript = FinalTranscript(text: "echo SHOULD_NOT_RUN\r\nnext\tpart\u{0007}")

        let safe = TranscriptPolicy.safeText(from: transcript, for: token)

        #expect(safe?.value == "echo SHOULD_NOT_RUN next part")
        #expect(safe?.value.contains("\r") == false)
        #expect(safe?.value.contains("\n") == false)
        #expect(safe?.value.contains("\t") == false)
    }
}

private actor AudioFake: AudioCapturing {
    func start(sessionID: UUID) async throws {}

    func stop(sessionID: UUID) async throws -> CapturedUtterance {
        CapturedUtterance(samples: Array(repeating: 0.1, count: 1_600), sampleRate: 16_000)
    }

    func cancel(sessionID: UUID) async {}
}

private actor TranscriberFake: Transcribing {
    let text: String

    init(text: String) {
        self.text = text
    }

    func transcribeFinal(
        _ utterance: CapturedUtterance,
        sessionID: UUID
    ) async throws -> FinalTranscript {
        FinalTranscript(text: text)
    }

    func cancel(sessionID: UUID) async {}
}

private enum ExpectedTranscriptionFailure: Error {
    case failed
}

private actor FailsOnceTranscriberFake: Transcribing {
    private var shouldFail = true

    func transcribeFinal(
        _ utterance: CapturedUtterance,
        sessionID: UUID
    ) async throws -> FinalTranscript {
        if shouldFail {
            shouldFail = false
            throw ExpectedTranscriptionFailure.failed
        }
        return FinalTranscript(text: "recovered")
    }

    func cancel(sessionID: UUID) async {}
}

private actor TargetFake: TargetTracking {
    let valid: Bool
    let token = TargetToken(kind: .standard)

    init(valid: Bool) {
        self.valid = valid
    }

    func captureTarget() async -> TargetToken? {
        token
    }

    func isStillValid(_ token: TargetToken) async -> Bool {
        valid
    }
}

private actor InsertionFake: TextInserting {
    private(set) var insertions: [String] = []

    func insert(
        _ text: SafeInsertionText,
        into target: TargetToken,
        sessionID: UUID
    ) async -> InsertionResult {
        insertions.append(text.value)
        return .inserted
    }
}
