import AVFoundation
import Foundation
import Testing
@testable import WhisperDictationFeature

struct WhisperModelEvalSmokeTests {
    @Test
    func missingModelFailsWithoutStartingADownload() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let transcriber = WhisperKitTranscriber(
            model: WhisperModelConfiguration(cacheRoot: cacheRoot)
        )

        await #expect(throws: WhisperKitTranscriberError.self) {
            try await transcriber.transcribeFinal(
                CapturedUtterance(
                    samples: Array(repeating: 0.1, count: 1_600),
                    sampleRate: 16_000
                ),
                sessionID: UUID()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.path))
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["WHISPER_EVAL_AUDIO"] != nil,
            "Run scripts/smoke-model.sh to supply the deterministic audio fixture."
        )
    )
    func localModelTranscribesKnownSpeech() async throws {
        let path = try #require(
            ProcessInfo.processInfo.environment["WHISPER_EVAL_AUDIO"]
        )
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            )
        )
        try file.read(into: buffer)

        let utterance = try AudioPCMNormalizer.normalize(buffer)
        let modelName = ProcessInfo.processInfo.environment[
            "WHISPER_EVAL_MODEL"
        ] ?? WhisperModelConfiguration.recommendedModel
        let cacheRoot = ProcessInfo.processInfo.environment[
            "WHISPER_EVAL_CACHE_ROOT"
        ].map { URL(fileURLWithPath: $0) }
            ?? WhisperModelConfiguration.defaultCacheRoot
        let configuration = WhisperModelConfiguration(
            modelName: modelName,
            cacheRoot: cacheRoot
        )
        let wasInstalled = configuration.isInstalled
        let transcriber = WhisperKitTranscriber(model: configuration)
        if !wasInstalled {
            #expect(
                ProcessInfo.processInfo.environment[
                    "WHISPER_EVAL_ALLOW_DOWNLOAD"
                ] == "1"
            )
            try await transcriber.prepare()
        }

        let coldStart = ContinuousClock.now
        let result = try await transcriber.transcribeFinal(
            utterance,
            sessionID: UUID()
        )
        let coldSeconds = seconds(since: coldStart)
        let normalized = result.text
            .lowercased()
            .filter { $0.isLetter || $0.isWhitespace }

        let expected = ProcessInfo.processInfo.environment[
            "WHISPER_EVAL_EXPECTED"
        ] ?? "quick brown fox jumps over the lazy dog"
        let normalizedExpected = expected
            .lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
        let wordErrorRate = Self.wordErrorRate(
            reference: normalizedExpected,
            hypothesis: normalized
        )
        if ProcessInfo.processInfo.environment[
            "WHISPER_EVAL_REQUIRE_MATCH"
        ] != "0" {
            #expect(normalized.contains(normalizedExpected))
        }

        let warmStart = ContinuousClock.now
        let warmResult = try await transcriber.transcribeFinal(
            utterance,
            sessionID: UUID()
        )
        let warmSeconds = seconds(since: warmStart)

        if ProcessInfo.processInfo.environment[
            "WHISPER_EVAL_REQUIRE_DETERMINISM"
        ] != "0" {
            #expect(warmResult.text == result.text)
        }
        let maxWarmSeconds = Double(
            ProcessInfo.processInfo.environment[
                "WHISPER_EVAL_MAX_WARM_SECONDS"
            ] ?? "1.5"
        ) ?? 1.5
        #expect(warmSeconds <= maxWarmSeconds)
        if wasInstalled {
            #expect(coldSeconds <= 8)
        }

        print(
            "WHISPER_EVAL model=\(modelName) cold_seconds=\(coldSeconds) "
                + "warm_seconds=\(warmSeconds) wer=\(wordErrorRate) "
                + "deterministic=\(warmResult.text == result.text) "
                + "text=\(result.text)"
        )
    }

    private static func wordErrorRate(
        reference: String,
        hypothesis: String
    ) -> Double {
        let referenceWords = reference.split(separator: " ").map(String.init)
        let hypothesisWords = hypothesis.split(separator: " ").map(String.init)
        var distances = Array(
            repeating: Array(repeating: 0, count: hypothesisWords.count + 1),
            count: referenceWords.count + 1
        )
        for row in 0...referenceWords.count { distances[row][0] = row }
        for column in 0...hypothesisWords.count { distances[0][column] = column }
        for row in 1...referenceWords.count {
            for column in 1...hypothesisWords.count {
                let substitution = referenceWords[row - 1]
                    == hypothesisWords[column - 1] ? 0 : 1
                distances[row][column] = min(
                    distances[row - 1][column] + 1,
                    distances[row][column - 1] + 1,
                    distances[row - 1][column - 1] + substitution
                )
            }
        }
        guard !referenceWords.isEmpty else {
            return hypothesisWords.isEmpty ? 0 : 1
        }
        return Double(distances[referenceWords.count][hypothesisWords.count])
            / Double(referenceWords.count)
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
