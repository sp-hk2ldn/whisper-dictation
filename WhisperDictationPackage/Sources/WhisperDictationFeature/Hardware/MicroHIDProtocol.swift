import Foundation

struct MicroReply: Equatable, Sendable {
    let id: Int
    let succeeded: Bool
    let version: String?
}

enum MicroMessage: Equatable, Sendable {
    case reply(MicroReply)
    case notification(MicroInput)
}

enum MicroCommand: Equatable, Sendable {
    case threadsLighting([MicroLightSetting])
    case lightingConfig(keys: MicroLightSetting, ambient: MicroLightSetting)
}

enum MicroWritePlan {
    static func commands(
        for picture: MicroPicture,
        after applied: MicroPicture?
    ) -> [MicroCommand] {
        let config = MicroCommand.lightingConfig(
            keys: picture.keys,
            ambient: picture.ambient
        )
        let threads = MicroCommand.threadsLighting(picture.slots)
        guard let applied else { return [config, threads] }
        let configChanged = applied.keys != picture.keys
            || applied.ambient != picture.ambient
        let threadsChanged = applied.slots != picture.slots
        return (configChanged ? [config] : []) + (threadsChanged ? [threads] : [])
    }
}

enum MicroHIDProtocol {
    static let statusMethod = "device.status"

    static func method(for command: MicroCommand) -> String {
        switch command {
        case .threadsLighting: "v.oai.thstatus"
        case .lightingConfig: "v.oai.rgbcfg"
        }
    }

    static func parameters(for command: MicroCommand) -> Any {
        switch command {
        case let .threadsLighting(slots):
            slots.enumerated().map { offset, setting in
                zone(setting).merging(["id": offset, "sk": 0, "sa": 0]) { first, _ in first }
            }
        case let .lightingConfig(keys, ambient):
            ["keys": zone(keys), "ambient": zone(ambient)]
        }
    }

    static func reports(
        method: String,
        parameters: Any?,
        id: Int,
        bluetooth: Bool
    ) throws -> [[UInt8]] {
        let object: [String: Any] = [
            "method": method,
            "params": parameters ?? NSNull(),
            "id": id
        ]
        let bytes = Array(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        return stride(from: 0, to: bytes.count, by: 61).map { offset in
            let chunk = Array(bytes[offset..<min(offset + 61, bytes.count)])
            var report: [UInt8] = bluetooth
                ? [6, 2, UInt8(chunk.count)]
                : [2, UInt8(chunk.count)]
            report += chunk
            report += Array(repeating: 0, count: (bluetooth ? 64 : 63) - report.count)
            return report
        }
    }

    private static func zone(_ setting: MicroLightSetting) -> [String: Any] {
        [
            "e": setting.effect.rawValue,
            "b": setting.brightness,
            "s": setting.speed,
            "c": setting.color
        ]
    }

    struct MessageParser {
        private static let maximumPendingBytes = 16_384
        private static let maximumChunkBytes = 61
        private static let lineFeed: UInt8 = 10

        private var pending: [UInt8] = []

        mutating func receive(_ report: [UInt8]) -> [MicroMessage] {
            let start = report.first == 6 ? 1 : 0
            guard report.count >= start + 2, report[start] == 2 else { return [] }
            let count = Int(report[start + 1])
            guard
                count <= Self.maximumChunkBytes,
                report.count >= start + 2 + count
            else { return [] }
            pending += report[(start + 2)..<(start + 2 + count)]
            guard pending.count <= Self.maximumPendingBytes else {
                pending.removeAll()
                return []
            }
            guard let lastLineFeed = pending.lastIndex(of: Self.lineFeed) else {
                return []
            }
            let complete = pending[..<lastLineFeed]
            pending.removeSubrange(...lastLineFeed)
            return complete
                .split(separator: Self.lineFeed)
                .compactMap { Self.message(from: Data($0)) }
        }

        private static func message(from line: Data) -> MicroMessage? {
            guard
                let object = (try? JSONSerialization.jsonObject(with: line))
                    as? [String: Any]
            else { return nil }
            guard let id = (object["id"] ?? object["i"]) as? Int else {
                return notification(from: object).map { .notification($0) }
            }
            return .reply(reply(id: id, from: object))
        }

        private static func reply(id: Int, from object: [String: Any]) -> MicroReply {
            let failed = object["error"].map { !($0 is NSNull) } ?? false
            let result = object["result"] as? [String: Any]
            return MicroReply(
                id: id,
                succeeded: !failed && object.keys.contains("result"),
                version: result?["version"] as? String
            )
        }

        private static func notification(from object: [String: Any]) -> MicroInput? {
            guard let method = (object["method"] ?? object["m"]) as? String else {
                return nil
            }
            let parameters = (object["params"] ?? object["p"]) as? [String: Any]
            switch method {
            case "v.oai.hid":
                guard let key = parameters?["k"] as? String else {
                    return .other(method: method)
                }
                return .key(
                    key: key,
                    act: parameters?["act"] as? Int,
                    agent: parameters?["ag"] as? Int
                )
            case "v.oai.rad":
                guard
                    let angle = parameters?["a"] as? Double,
                    let distance = parameters?["d"] as? Double
                else { return .other(method: method) }
                return .joystick(angle: angle, distance: distance)
            default:
                return .other(method: method)
            }
        }
    }
}

enum MicroLightingError: Error, Equatable {
    case disconnected, permissionDenied, transport, timeout, rejected

    var message: String {
        switch self {
        case .disconnected: "Connect your Codex Micro."
        case .permissionDenied: "Enable Input Monitoring for Whisper Dictation."
        case .transport, .timeout, .rejected: "Micro lighting is unavailable. Reconnect the keyboard to retry."
        }
    }
}
