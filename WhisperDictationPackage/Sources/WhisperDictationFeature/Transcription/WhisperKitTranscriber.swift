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
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        return applicationSupport
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
    private let model: WhisperModelConfiguration
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
        let engine = try await loadEngineIfNeeded(allowDownload: false)
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

        let results = try await engine.transcribe(
            audioArray: utterance.samples,
            decodeOptions: options
        )
        try checkCancellation(for: sessionID)

        let text = results
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw WhisperKitTranscriberError.emptyTranscript
        }

        return FinalTranscript(text: text)
    }

    public func cancel(sessionID: UUID) async {
        cancelledSessions.insert(sessionID)
    }

    public func unload() async {
        await engine?.unloadModels()
        engine = nil
    }

    private func loadEngineIfNeeded(allowDownload: Bool) async throws -> WhisperKit {
        if let engine {
            return engine
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

        let loadedEngine = try await WhisperKit(config)
        engine = loadedEngine
        return loadedEngine
    }

    private func checkCancellation(for sessionID: UUID) throws {
        if cancelledSessions.remove(sessionID) != nil || Task.isCancelled {
            throw WhisperKitTranscriberError.cancelled
        }
    }
}
