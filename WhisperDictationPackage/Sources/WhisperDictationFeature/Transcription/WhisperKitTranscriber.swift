import Foundation
import WhisperKit

public enum WhisperKitTranscriberError: LocalizedError {
    case invalidAudioFormat
    case cancelled
    case emptyTranscript
    case modelNotInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            "WhisperKit requires non-empty 16 kHz mono audio."
        case .cancelled:
            "Transcription was cancelled."
        case .emptyTranscript:
            "No speech was detected."
        case .modelNotInstalled:
            "Download the local Whisper model before dictating."
        }
    }
}

public struct WhisperModelConfiguration: Sendable, Equatable {
    public static let recommendedModel = "large-v3-v20240930_626MB"
    public static let repository = "argmaxinc/whisperkit-coreml"

    public let modelName: String
    public let cacheRoot: URL

    public init(
        modelName: String = Self.recommendedModel,
        cacheRoot: URL = Self.defaultCacheRoot
    ) {
        self.modelName = modelName
        self.cacheRoot = cacheRoot
    }

    public static var defaultCacheRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "WhisperDictation", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    public var expectedModelFolder: URL {
        cacheRoot
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
            .appending(
                path: "openai_whisper-\(modelName)",
                directoryHint: .isDirectory
            )
    }

    public var expectedTokenizerFolder: URL {
        cacheRoot
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "openai", directoryHint: .isDirectory)
            .appending(path: "whisper-large-v3", directoryHint: .isDirectory)
    }

    public var isInstalled: Bool {
        let expectedNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: expectedModelFolder,
                includingPropertiesForKeys: nil
            )
        else {
            return false
        }

        let hasModels = expectedNames.allSatisfy { name in
            contents.contains { url in
                url.lastPathComponent.hasPrefix(name)
                    && (url.pathExtension == "mlmodelc" || url.pathExtension == "mlpackage")
            }
        }
        let tokenizer = expectedTokenizerFolder.appending(path: "tokenizer.json")
        return hasModels && FileManager.default.fileExists(atPath: tokenizer.path)
    }
}

public actor WhisperKitTranscriber: Transcribing {
    private struct LoadedEngine {
        let engine: WhisperKit
        let loadDuration: Duration?
    }

    private let model: WhisperModelConfiguration
    private let clock = ContinuousClock()
    private var engine: WhisperKit?
    private var cancelledSessions: Set<UUID> = []

    public init(model: WhisperModelConfiguration = WhisperModelConfiguration()) {
        self.model = model
    }

    public func prepare() async throws {
        _ = try await loadEngineIfNeeded(allowDownload: true)
    }

    public func transcribeFinal(
        _ utterance: CapturedUtterance,
        sessionID: UUID
    ) async throws -> FinalTranscript {
        guard
            utterance.sampleRate == Double(WhisperKit.sampleRate),
            !utterance.samples.isEmpty
        else {
            throw WhisperKitTranscriberError.invalidAudioFormat
        }

        cancelledSessions.remove(sessionID)
        defer { cancelledSessions.remove(sessionID) }
        let loaded = try await loadEngineIfNeeded(allowDownload: false)
        try checkCancellation(for: sessionID)

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            wordTimestamps: false
        )

        let results = try await transcriptionResults(
            for: utterance.samples,
            engine: loaded.engine,
            options: options
        )

        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !text.isEmpty else {
            try checkCancellation(for: sessionID)
            throw WhisperKitTranscriberError.emptyTranscript
        }

        return FinalTranscript(text: text, modelLoadDuration: loaded.loadDuration)
    }

    public func cancel(sessionID: UUID) async {
        cancelledSessions.insert(sessionID)
    }

    public func unload() async {
        await engine?.unloadModels()
        engine = nil
    }

    private func transcriptionResults(
        for samples: [Float],
        engine: WhisperKit,
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        let windowSamples = engine.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        guard samples.count > windowSamples else {
            return try await engine.transcribe(audioArray: samples, decodeOptions: options)
        }

        // The default padding stops chunking with up to one second of audio
        // left over, which drops the end of the dictation.
        let chunker = VADAudioChunker(windowPadding: 0, vad: EnergyVAD())
        let chunks = try await chunker.chunkAll(
            audioArray: samples,
            maxChunkLength: windowSamples,
            decodeOptions: options
        )
        let audioArrays = chunks.map { $0.audioSamples }
        let results = await engine.transcribeWithResults(
            audioArrays: audioArrays,
            decodeOptions: options
        )
        let chunkResults = try results.map { try $0.get() }
        return chunkResults.flatMap { $0 }
    }

    private func loadEngineIfNeeded(allowDownload: Bool) async throws -> LoadedEngine {
        if let engine {
            return LoadedEngine(engine: engine, loadDuration: nil)
        }

        guard model.isInstalled || allowDownload else {
            throw WhisperKitTranscriberError.modelNotInstalled
        }

        try FileManager.default.createDirectory(
            at: model.cacheRoot,
            withIntermediateDirectories: true
        )
        var cacheValues = URLResourceValues()
        cacheValues.isExcludedFromBackup = true
        var cacheRoot = model.cacheRoot
        try? cacheRoot.setResourceValues(cacheValues)

        let config: WhisperKitConfig
        if model.isInstalled {
            config = WhisperKitConfig(
                modelFolder: model.expectedModelFolder.path,
                tokenizerFolder: model.cacheRoot,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
        } else {
            config = WhisperKitConfig(
                model: model.modelName,
                downloadBase: model.cacheRoot,
                modelRepo: WhisperModelConfiguration.repository,
                verbose: false,
                prewarm: false,
                load: true,
                download: true
            )
        }

        let loadStart = clock.now
        let loadedEngine = try await WhisperKit(config)
        let loadDuration = loadStart.duration(to: clock.now)
        engine = loadedEngine
        return LoadedEngine(engine: loadedEngine, loadDuration: loadDuration)
    }

    private func checkCancellation(for sessionID: UUID) throws {
        if cancelledSessions.remove(sessionID) != nil || Task.isCancelled {
            throw WhisperKitTranscriberError.cancelled
        }
    }
}
