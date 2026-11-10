import AVFoundation
import AudioExceptionBridge
import Testing
@testable import WhisperDictationFeature

struct AudioCaptureSmokeTests {
    @Test
    func audioSetupExceptionBecomesRecoverableError() throws {
        let error = try #require(WDPerformAudioSetup {
            NSException(
                name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                reason: "Failed to create tap due to format mismatch",
                userInfo: nil
            ).raise()
        })
        #expect((error as NSError).domain == "WhisperDictation.AudioSetup")
        #expect((error as NSError).localizedFailureReason == "Failed to create tap due to format mismatch")
        var didRun = false
        #expect(WDPerformAudioSetup { didRun = true } == nil)
        #expect(didRun)
    }

    @Test
    func interruptedCaptureRecoversWithNewMicrophoneFormat() throws {
        let store = NativeAudioBufferStore()
        func buffer(rate: Double) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
            buffer.floatChannelData![0].initialize(repeating: 0.2, count: 512)
            return buffer
        }
        store.beginCapture()
        store.append(buffer(rate: 44_100))
        store.invalidate()
        #expect(throws: AudioCaptureError.self) { try store.takeCombinedBuffer() }
        // Consuming an interrupted recording must not mark its engine reusable.
        #expect(store.isInvalidated)
        store.reset()
        store.beginCapture()
        store.append(buffer(rate: 48_000))
        let recovered = try #require(try store.takeCombinedBuffer())
        #expect(recovered.format.sampleRate == 48_000)
        #expect(recovered.frameLength == 512)
        #expect(!store.isInvalidated)
    }

    @Test
    func consecutiveCapturesExcludeAudioBetweenShortcutHolds() throws {
        let store = NativeAudioBufferStore()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
            for index in 0..<512 { buffer.floatChannelData![0][index] = value }
            return buffer
        }
        store.beginCapture()
        store.append(buffer(0.1))
        let first = try #require(try store.takeCombinedBuffer())
        store.append(buffer(0.9)) // Discarded while the engine stays warm.
        store.beginCapture()
        store.append(buffer(0.2))
        let second = try #require(try store.takeCombinedBuffer())
        #expect(first.frameLength == 512)
        #expect(second.frameLength == 512)
        #expect(first.floatChannelData![0][0] == 0.1)
        #expect(second.floatChannelData![0][0] == 0.2)
        store.append(buffer(0.9))
        #expect(try store.takeCombinedBuffer() == nil)
    }

    @Test
    func normalizes48kStereoFloat32ToWhisperFormat() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let frameCount: AVAudioFrameCount = 48_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        for index in 0..<Int(frameCount) {
            let sample = Float(index % 256) / 256 - 0.5
            channels[0][index] = sample
            channels[1][index] = -sample
        }

        let utterance = try AudioPCMNormalizer.normalize(buffer)

        #expect(utterance.sampleRate == 16_000)
        #expect(utterance.samples.allSatisfy { $0.isFinite })
        #expect(abs(utterance.duration - 1) <= 0.001)
    }
}
