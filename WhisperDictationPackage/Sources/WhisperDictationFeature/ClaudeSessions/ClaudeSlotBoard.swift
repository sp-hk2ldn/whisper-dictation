import Foundation

struct ClaudeSlot: Equatable, Sendable {
    let record: ClaudeSessionRecord
    let isAcknowledged: Bool

    var state: ClaudeSessionState {
        record.state == .unread && isAcknowledged ? .idle : record.state
    }
}

struct ClaudeSlotBoard: Equatable, Sendable {
    static let slotCount = 6
    static let empty = ClaudeSlotBoard(
        slots: Array(repeating: nil, count: slotCount),
        selectedSlot: nil,
        selectionChangedAt: nil,
        followedFocusID: nil
    )

    let slots: [ClaudeSlot?]
    let selectedSlot: Int?
    let selectionChangedAt: Date?
    let followedFocusID: String?
}

struct ClaudeSlotAssigner: Sendable {
    private struct SlotStamp {
        let index: Int
        let updatedAt: Date
    }

    private struct Selection {
        let slot: Int?
        let changedAt: Date?
    }

    func applying(
        _ records: [ClaudeSessionRecord],
        to board: ClaudeSlotBoard,
        focusedSessionID: String?,
        now: Date
    ) -> ClaudeSlotBoard {
        let latest = Dictionary(
            records.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let kept = board.slots.map { slot in
            slot.flatMap { refreshed($0, from: latest) }
        }
        let seated = Set(kept.compactMap { $0?.record.sessionID })
        let waiting = records
            .filter { !seated.contains($0.sessionID) }
            .sorted(by: isNewer)
        let placed = waiting.reduce(kept) { slots, record in
            placing(record, in: slots)
        }
        return selecting(
            after: board,
            slots: placed,
            focusedSessionID: focusedSessionID,
            now: now
        )
    }

    func pressing(
        slot: Int,
        on board: ClaudeSlotBoard,
        now: Date
    ) -> ClaudeSlotBoard {
        guard
            board.slots.indices.contains(slot),
            let pressed = board.slots[slot]
        else { return board }
        var slots = board.slots
        slots[slot] = ClaudeSlot(record: pressed.record, isAcknowledged: true)
        let selectionChangedAt = board.selectedSlot == slot
            ? board.selectionChangedAt
            : now
        return ClaudeSlotBoard(
            slots: slots,
            selectedSlot: slot,
            selectionChangedAt: selectionChangedAt,
            followedFocusID: board.followedFocusID
        )
    }

    private func refreshed(
        _ slot: ClaudeSlot,
        from latest: [String: ClaudeSessionRecord]
    ) -> ClaudeSlot? {
        guard let record = latest[slot.record.sessionID] else { return nil }
        guard record != slot.record else { return slot }
        return ClaudeSlot(record: record, isAcknowledged: false)
    }

    private func isNewer(
        _ lhs: ClaudeSessionRecord,
        _ rhs: ClaudeSessionRecord
    ) -> Bool {
        guard lhs.updatedAt != rhs.updatedAt else {
            return lhs.sessionID < rhs.sessionID
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func placing(
        _ record: ClaudeSessionRecord,
        in slots: [ClaudeSlot?]
    ) -> [ClaudeSlot?] {
        guard let index = slots.firstIndex(where: { $0 == nil })
            ?? evictableIndex(in: slots, olderThan: record.updatedAt)
        else { return slots }
        var placed = slots
        placed[index] = ClaudeSlot(record: record, isAcknowledged: false)
        return placed
    }

    private func evictableIndex(
        in slots: [ClaudeSlot?],
        olderThan date: Date
    ) -> Int? {
        let candidates = slots.enumerated().compactMap { offset, slot -> SlotStamp? in
            guard
                let slot,
                slot.state == .idle || slot.state == .unread,
                slot.record.updatedAt < date
            else { return nil }
            return SlotStamp(index: offset, updatedAt: slot.record.updatedAt)
        }
        return candidates.min { $0.updatedAt < $1.updatedAt }?.index
    }

    private func selecting(
        after previous: ClaudeSlotBoard,
        slots: [ClaudeSlot?],
        focusedSessionID: String?,
        now: Date
    ) -> ClaudeSlotBoard {
        let retained = retainedSelection(after: previous, slots: slots)
        let selection = newSelection(
            retained: retained,
            previous: previous,
            slots: slots,
            focusedSessionID: focusedSessionID,
            now: now
        )
        return ClaudeSlotBoard(
            slots: slots,
            selectedSlot: selection.slot,
            selectionChangedAt: selection.changedAt,
            followedFocusID: focusedSessionID
        )
    }

    private func retainedSelection(
        after previous: ClaudeSlotBoard,
        slots: [ClaudeSlot?]
    ) -> Selection {
        let selectedID = previous.selectedSlot.flatMap {
            previous.slots[$0]?.record.sessionID
        }
        let slot = selectedID.flatMap { index(of: $0, in: slots) }
        return Selection(
            slot: slot,
            changedAt: slot == nil ? nil : previous.selectionChangedAt
        )
    }

    private func newSelection(
        retained: Selection,
        previous: ClaudeSlotBoard,
        slots: [ClaudeSlot?],
        focusedSessionID: String?,
        now: Date
    ) -> Selection {
        let focusedSlot = focusedSessionID.flatMap { index(of: $0, in: slots) }
        guard let focusedSlot else {
            return latestWorkingStart(in: slots, after: previous)
                .map { selected($0, retained: retained, now: now) } ?? retained
        }
        let focusChanged = focusedSessionID != previous.followedFocusID
        guard focusChanged || retained.slot == nil else { return retained }
        return selected(focusedSlot, retained: retained, now: now)
    }

    private func selected(
        _ index: Int,
        retained: Selection,
        now: Date
    ) -> Selection {
        Selection(
            slot: index,
            changedAt: index == retained.slot ? retained.changedAt : now
        )
    }

    private func index(of sessionID: String, in slots: [ClaudeSlot?]) -> Int? {
        slots.firstIndex { $0?.record.sessionID == sessionID }
    }

    private func latestWorkingStart(
        in slots: [ClaudeSlot?],
        after previous: ClaudeSlotBoard
    ) -> Int? {
        let started = slots.enumerated().compactMap { offset, slot -> SlotStamp? in
            guard
                let slot,
                startedWorking(slot, before: previous.slots[offset])
            else { return nil }
            return SlotStamp(index: offset, updatedAt: slot.record.updatedAt)
        }
        return started.max { $0.updatedAt < $1.updatedAt }?.index
    }

    private func startedWorking(
        _ slot: ClaudeSlot,
        before previous: ClaudeSlot?
    ) -> Bool {
        guard slot.record.state == .working else { return false }
        guard
            let previous,
            previous.record.sessionID == slot.record.sessionID
        else { return true }
        return previous.record.state != .working
    }
}
