@preconcurrency import AVFoundation

public enum AudioPCMNormalizer {
    public static let targetSampleRate = 16_000.0

    public static func normalize(_ buffer: AVAudioPCMBuffer) throws -> CapturedUtterance {
        let input = buffer.format
        guard input.commonFormat == .pcmFormatFloat32,
              input.sampleRate > 0,
              input.channelCount > 0,
              buffer.frameLength > 0 else {
            throw NormalizationError.invalidInput
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: input, to: outputFormat) else {
            throw NormalizationError.conversionFailed
        }

        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetSampleRate / input.sampleRate) + 32
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw NormalizationError.conversionFailed
        }

        let inputProvider = ConverterInput(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !inputProvider.supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputProvider.supplied = true
            inputStatus.pointee = .haveData
            return inputProvider.buffer
        }

        guard (status == .haveData || status == .endOfStream),
              error == nil,
              output.frameLength > 0,
              let channels = output.floatChannelData else {
            throw NormalizationError.conversionFailed
        }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
        guard samples.allSatisfy(\.isFinite) else {
            throw NormalizationError.conversionFailed
        }
        return CapturedUtterance(samples: samples, sampleRate: targetSampleRate)
    }

    public enum NormalizationError: Error, Equatable, Sendable {
        case invalidInput
        case conversionFailed
    }
}

private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
