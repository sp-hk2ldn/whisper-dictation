import Foundation

public struct CapturedUtterance: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

public struct FinalTranscript: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public enum TargetKind: Sendable, Equatable {
    case standard
    case terminal
}

public struct TargetToken: Sendable, Equatable {
    public let id: UUID
    public let kind: TargetKind

    public init(id: UUID = UUID(), kind: TargetKind) {
        self.id = id
        self.kind = kind
    }
}

public struct SafeInsertionText: Sendable, Equatable {
    public let value: String

    init(value: String) {
        self.value = value
    }
}

public enum InsertionResult: Sendable, Equatable {
    case inserted
    case refused
}

public protocol AudioCapturing: Sendable {
    func start(sessionID: UUID) async throws
    func stop(sessionID: UUID) async throws -> CapturedUtterance
    func finishBatch() async
    func cancel(sessionID: UUID) async
}

public extension AudioCapturing {
    func finishBatch() async {}
}

public protocol Transcribing: Sendable {
    func transcribeFinal(
        _ utterance: CapturedUtterance,
        sessionID: UUID
    ) async throws -> FinalTranscript

    func cancel(sessionID: UUID) async
}

public protocol TargetTracking: Sendable {
    func captureTarget() async -> TargetToken?
    func isStillValid(_ token: TargetToken) async -> Bool
    func releaseTarget(_ token: TargetToken) async
}

public protocol TextInserting: Sendable {
    func insert(
        _ text: SafeInsertionText,
        into target: TargetToken,
        sessionID: UUID
    ) async -> InsertionResult
}

public extension TargetTracking {
    func releaseTarget(_ token: TargetToken) async {}
}
