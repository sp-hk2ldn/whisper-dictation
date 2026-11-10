import AVFoundation
import Foundation

public actor FixtureAudioCapture: AudioCapturing {
    private let audioURL: URL
    private var activeSessionID: UUID?

    public init(audioURL: URL) {
        self.audioURL = audioURL
    }

    public func start(sessionID: UUID) async throws {
        guard activeSessionID == nil else {
            throw AudioCaptureError.alreadyRecording
        }
        activeSessionID = sessionID
    }

    public func stop(sessionID: UUID) async throws -> CapturedUtterance {
        guard activeSessionID == sessionID else {
            throw AudioCaptureError.notRecording
        }
        activeSessionID = nil

        let file = try AVAudioFile(forReading: audioURL)
        guard
            file.length > 0,
            file.length <= AVAudioFramePosition(UInt32.max),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw AudioCaptureError.noAudio
        }

        try file.read(into: buffer)
        return try AudioPCMNormalizer.normalize(buffer)
    }

    public func cancel(sessionID: UUID) async {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }
}
