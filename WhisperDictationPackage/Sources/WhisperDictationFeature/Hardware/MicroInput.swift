import Foundation

enum MicroInput: Equatable, Sendable {
    case key(key: String, act: Int?, agent: Int?)
    case joystick(angle: Double, distance: Double)
    case keyboard(usagePage: Int, usage: Int, act: Int)
    case other(method: String)
}

enum MicroSlotKey {
    static let pressedActValue = 1

    static func name(for slot: Int) -> String {
        "AG0\(slot)"
    }

    static let slotsByKey = Dictionary(
        uniqueKeysWithValues: (0..<ClaudeSlotBoard.slotCount).map {
            (name(for: $0), $0)
        }
    )
}

enum MicroActionKey: String, Equatable, Sendable {
    case stop = "ACT06"
    case approve = "ACT07"
    case reject = "ACT08"
    case newTask = "ACT09"
    case waiting = "ACT12"
}

enum MicroPress: Equatable, Sendable {
    case slot(Int)
    case action(MicroActionKey)

    init?(_ input: MicroInput) {
        guard
            case let .key(key, act, _) = input,
            act == MicroSlotKey.pressedActValue
        else { return nil }
        if let slot = MicroSlotKey.slotsByKey[key] {
            self = .slot(slot)
            return
        }
        guard let action = MicroActionKey(rawValue: key) else { return nil }
        self = .action(action)
    }

    var keyName: String {
        switch self {
        case .slot(let slot): MicroSlotKey.name(for: slot)
        case .action(let action): action.rawValue
        }
    }
}

struct MicroInputDiagnosticLog: Equatable, Sendable {
    static let capacity = 50

    let lines: [String]

    func appending(_ input: MicroInput, at time: Date) -> MicroInputDiagnosticLog {
        appending(line: Self.description(of: input), at: time)
    }

    func appending(action: String, at time: Date) -> MicroInputDiagnosticLog {
        appending(line: "action \(action)", at: time)
    }

    private func appending(line: String, at time: Date) -> MicroInputDiagnosticLog {
        MicroInputDiagnosticLog(
            lines: Array((lines + ["\(time.ISO8601Format()) \(line)"]).suffix(Self.capacity))
        )
    }

    private static func description(of input: MicroInput) -> String {
        switch input {
        case let .key(key, act, agent):
            "hid key=\(key) act=\(describe(act)) agent=\(describe(agent))"
        case let .joystick(angle, distance):
            "joystick angle=\(angle) distance=\(distance)"
        case let .keyboard(usagePage, usage, act):
            "keyboard page=\(usagePage) usage=\(usage) act=\(act)"
        case let .other(method):
            "notification method=\(method)"
        }
    }

    private static func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }
}
