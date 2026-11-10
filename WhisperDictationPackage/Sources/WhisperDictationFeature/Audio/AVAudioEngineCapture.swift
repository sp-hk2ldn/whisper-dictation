@preconcurrency import AVFoundation
import AudioExceptionBridge
import Foundation

public enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidInputFormat
    case incompatibleBufferFormats
    case noAudio
    case interrupted

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A recording is already active."
        case .notRecording:
            "No matching recording is active."
        case .invalidInputFormat:
            "The selected microphone has an unsupported audio format."
        case .incompatibleBufferFormats:
            "The microphone format changed during recording."
        case .noAudio:
            "No microphone audio was captured."
        case .interrupted:
            "The microphone changed or was interrupted while recording."
        }
    }
}

public actor AVAudioEngineCapture: AudioCapturing {
    private var engine: AVAudioEngine
    private var hasInputTap = false
    private let store = NativeAudioBufferStore()
    private var activeSessionID: UUID?
    private var configurationObserver: NSObjectProtocol?

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public func start(sessionID: UUID) async throws {
        guard activeSessionID == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        if hasInputTap && engine.isRunning && !store.isInvalidated {
            store.beginCapture()
            activeSessionID = sessionID
            return
        }

        // Stopped engines can retain the previous device's sample rate. Retire
        // both the graph and its tap before consulting the current microphone.
        stopEngine()
        store.reset()
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard
            format.sampleRate > 0,
            format.channelCount > 0,
            format.commonFormat == .pcmFormatFloat32
        else {
            throw AudioCaptureError.invalidInputFormat
        }

        store.beginCapture()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [store] _ in
            store.invalidate()
        }
        do {
            let setupError = WDPerformAudioSetup {
                // nil follows the bus format rather than applying a snapshot
                // which may already be stale after an audio-route change.
                input.installTap(onBus: 0, bufferSize: 512, format: nil) { [store] buffer, _ in
                    if let copy = Self.copy(buffer) {
                        store.append(copy)
                    }
                }
                hasInputTap = true
                engine.prepare()
            }
            if let setupError { throw setupError }
            try engine.start()
            guard !store.isInvalidated else { throw AudioCaptureError.interrupted }
            activeSessionID = sessionID
        } catch {
            stopEngine()
            store.reset()
            throw error
        }
    }

    public func stop(sessionID: UUID) async throws -> CapturedUtterance {
        guard activeSessionID == sessionID else {
            throw AudioCaptureError.notRecording
        }

        activeSessionID = nil

        guard let combined = try store.takeCombinedBuffer() else {
            throw AudioCaptureError.noAudio
        }
        return try AudioPCMNormalizer.normalize(combined)
    }

    public func cancel(sessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        stopEngine()
        store.reset()
        activeSessionID = nil
    }

    public func finishBatch() async {
        guard activeSessionID == nil else { return }
        stopEngine()
        store.reset()
    }

    private func stopEngine() {
        removeConfigurationObserver()
        engine.stop()
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
    }

    private func removeConfigurationObserver() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    private nonisolated static func copy(
        _ buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard
            let sourceChannels = buffer.floatChannelData,
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            ),
            let destinationChannels = copy.floatChannelData
        else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size

        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destinationChannels[channel], sourceChannels[channel], byteCount)
        }
        return copy
    }
}

final class NativeAudioBufferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var wasInvalidated = false
    private var isCapturing = false

    var isInvalidated: Bool {
        lock.withLock { wasInvalidated }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard isCapturing else { return }
            buffers.append(buffer)
        }
    }

    func beginCapture() {
        lock.withLock {
            buffers.removeAll(keepingCapacity: true)
            isCapturing = true
        }
    }

    func reset() {
        lock.withLock {
            isCapturing = false
            buffers.removeAll(keepingCapacity: true)
            wasInvalidated = false
        }
    }

    func invalidate() {
        lock.withLock {
            wasInvalidated = true
            buffers.removeAll(keepingCapacity: true)
        }
    }

    func takeCombinedBuffer() throws -> AVAudioPCMBuffer? {
        let captured = lock.withLock {
            isCapturing = false
            let result = (buffers, wasInvalidated)
            buffers.removeAll(keepingCapacity: true)
            return result
        }

        guard !captured.1 else {
            throw AudioCaptureError.interrupted
        }
        guard let first = captured.0.first else { return nil }
        guard captured.0.allSatisfy({ $0.format == first.format }) else {
            throw AudioCaptureError.incompatibleBufferFormats
        }

        let totalFrames = captured.0.reduce(0) {
            $0 + AVAudioFramePosition($1.frameLength)
        }
        guard
            totalFrames <= AVAudioFramePosition(UInt32.max),
            let combined = AVAudioPCMBuffer(
                pcmFormat: first.format,
                frameCapacity: AVAudioFrameCount(totalFrames)
            ),
            let destinationChannels = combined.floatChannelData
        else {
            throw AudioCaptureError.invalidInputFormat
        }

        var destinationOffset = 0
        for buffer in captured.0 {
            guard let sourceChannels = buffer.floatChannelData else {
                throw AudioCaptureError.invalidInputFormat
            }

            let frameCount = Int(buffer.frameLength)
            let byteCount = frameCount * MemoryLayout<Float>.size
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(
                    destinationChannels[channel] + destinationOffset,
                    sourceChannels[channel],
                    byteCount
                )
            }
            destinationOffset += frameCount
        }

        combined.frameLength = AVAudioFrameCount(totalFrames)
        return combined
    }
}
