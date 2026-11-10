import Foundation

enum MicroEffect: Int, Sendable {
    case off
    case solid
    case snake
    case rainbow
    case breath
    case gradient
    case shallowBreath
}

struct MicroLightSetting: Equatable, Sendable {
    static let off = MicroLightSetting(
        effect: .off,
        color: 0,
        brightness: 0,
        speed: 0
    )

    let effect: MicroEffect
    let color: Int
    let brightness: Double
    let speed: Double
}

struct MicroPicture: Equatable, Sendable {
    static let allOff = MicroPicture(
        slots: Array(repeating: .off, count: ClaudeSlotBoard.slotCount),
        keys: .off,
        ambient: .off
    )

    let slots: [MicroLightSetting]
    let keys: MicroLightSetting
    let ambient: MicroLightSetting
}

enum MicroVoiceLight: Sendable, Equatable {
    case idle
    case recording
    case processing
    case completed
}

enum MicroPalette {
    static let working = 0x304FFE
    static let unread = 0x00FF4C
    static let idle = 0xFFFFFF
    static let awaiting = 0xFF6D00
    static let error = 0xFF0033
    static let recordingRing = 0x2E8B57
    static let processingRing = 0xFFFFFF
    static let completedRing = 0xFFFFFF

    static func color(for state: ClaudeSessionState) -> Int {
        switch state {
        case .working: working
        case .unread: unread
        case .idle: idle
        case .awaitingApproval, .awaitingResponse: awaiting
        case .error: error
        }
    }
}

struct MicroPictureBuilder: Sendable {
    static let highlightDuration: TimeInterval = 4
    static let animatedSpeed = 0.4

    func picture(
        board: ClaudeSlotBoard,
        voice: MicroVoiceLight,
        now: Date
    ) -> MicroPicture {
        MicroPicture(
            slots: board.slots.enumerated().map { offset, slot in
                slotLight(
                    slot,
                    isHighlighted: isHighlighted(
                        offset,
                        on: board,
                        now: now
                    )
                )
            },
            keys: .off,
            ambient: ambient(board: board, voice: voice)
        )
    }

    func isHighlighted(
        _ index: Int,
        on board: ClaudeSlotBoard,
        now: Date
    ) -> Bool {
        guard
            board.selectedSlot == index,
            let changedAt = board.selectionChangedAt
        else { return false }
        return now.timeIntervalSince(changedAt) < Self.highlightDuration
    }

    private func slotLight(
        _ slot: ClaudeSlot?,
        isHighlighted: Bool
    ) -> MicroLightSetting {
        guard let slot else { return .off }
        return MicroLightSetting(
            effect: isHighlighted ? .breath : .solid,
            color: MicroPalette.color(for: slot.state),
            brightness: 1,
            speed: isHighlighted ? Self.animatedSpeed : 0
        )
    }

    private func ambient(
        board: ClaudeSlotBoard,
        voice: MicroVoiceLight
    ) -> MicroLightSetting {
        switch voice {
        case .recording:
            return snakingRing(color: MicroPalette.recordingRing)
        case .processing:
            return snakingRing(color: MicroPalette.processingRing)
        case .completed:
            return MicroLightSetting(
                effect: .solid,
                color: MicroPalette.completedRing,
                brightness: 1,
                speed: 0
            )
        case .idle:
            return selectedWorkingRing(board)
        }
    }

    private func selectedWorkingRing(_ board: ClaudeSlotBoard) -> MicroLightSetting {
        guard
            let index = board.selectedSlot,
            board.slots.indices.contains(index),
            let slot = board.slots[index],
            slot.state == .working
        else { return .off }
        return snakingRing(color: MicroPalette.color(for: slot.state))
    }

    private func snakingRing(color: Int) -> MicroLightSetting {
        MicroLightSetting(
            effect: .snake,
            color: color,
            brightness: 1,
            speed: Self.animatedSpeed
        )
    }
}
