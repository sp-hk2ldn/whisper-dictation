import Foundation

struct ClaudeSlotTarget: Equatable, Sendable {
    let index: Int
    let slot: ClaudeSlot
}

struct ClaudeMicroContext: Sendable {
    let host: ClaudeSessionHost
    let board: ClaudeSlotBoard
    let focusedSessionID: String?
    let frontmost: FrontmostApplication?
}

enum ClaudeMicroFallback: Equatable, Sendable {
    case claudeNotFrontmost
    case focusedSessionNotOnBoard
    case focusedSessionNotIn(ClaudeSessionState)
    case t3HasNoShortcut
}

enum ClaudeMicroIgnoreReason: Equatable, Sendable {
    case emptySlot
    case noSession(in: ClaudeSessionState)
    case nothingWaiting
}

enum ClaudeMicroPlan: Equatable, Sendable {
    case openNewTask
    case openWaiting
    case openSlot(ClaudeSlotTarget)
    case redirect(ClaudeSlotTarget, because: ClaudeMicroFallback)
    case send(ClaudeKeystroke, toProcess: pid_t)
    case ignore(ClaudeMicroIgnoreReason)
}

struct ClaudeMicroActionPlanner: Sendable {
    func plan(for press: MicroPress, in context: ClaudeMicroContext) -> ClaudeMicroPlan {
        switch press {
        case .slot(let index): slotPlan(index, on: context.board)
        case .action(let action): actionPlan(action, in: context)
        }
    }

    private func slotPlan(_ index: Int, on board: ClaudeSlotBoard) -> ClaudeMicroPlan {
        guard
            board.slots.indices.contains(index),
            let slot = board.slots[index]
        else { return .ignore(.emptySlot) }
        return .openSlot(ClaudeSlotTarget(index: index, slot: slot))
    }

    private func actionPlan(
        _ action: MicroActionKey,
        in context: ClaudeMicroContext
    ) -> ClaudeMicroPlan {
        switch action {
        case .newTask:
            .openNewTask
        case .waiting:
            waitingPlan(in: context)
        case .approve:
            responding(with: .returnKey, whenSessionIs: .awaitingApproval, in: context)
        case .reject:
            responding(with: .escape, whenSessionIs: .awaitingApproval, in: context)
        case .stop:
            responding(with: .escape, whenSessionIs: .working, in: context)
        }
    }

    private func waitingPlan(in context: ClaudeMicroContext) -> ClaudeMicroPlan {
        guard context.host == .t3Code else { return .openWaiting }
        let target = [ClaudeSessionState.awaitingApproval, .awaitingResponse]
            .compactMap { mostRecentTarget(in: $0, in: context) }
            .max { $0.slot.record.updatedAt < $1.slot.record.updatedAt }
        guard let target else { return .ignore(.nothingWaiting) }
        return .openSlot(target)
    }

    private func responding(
        with keystroke: ClaudeKeystroke,
        whenSessionIs state: ClaudeSessionState,
        in context: ClaudeMicroContext
    ) -> ClaudeMicroPlan {
        guard let target = mostRecentTarget(in: state, in: context) else {
            return .ignore(.noSession(in: state))
        }
        guard context.host == .claudeDesktop else {
            return .redirect(target, because: .t3HasNoShortcut)
        }
        guard
            let frontmost = context.frontmost,
            frontmost.bundleIdentifier == KnownTextDestination.claude.rawValue
        else { return .redirect(target, because: .claudeNotFrontmost) }
        guard let focused = focusedSlot(in: context) else {
            return .redirect(target, because: .focusedSessionNotOnBoard)
        }
        guard focused.state == state else {
            return .redirect(target, because: .focusedSessionNotIn(state))
        }
        return .send(keystroke, toProcess: frontmost.processIdentifier)
    }

    private func focusedSlot(in context: ClaudeMicroContext) -> ClaudeSlot? {
        context.board.slots
            .compactMap { $0 }
            .first {
                $0.record.host == .claudeDesktop
                    && $0.record.sessionID == context.focusedSessionID
            }
    }

    private func mostRecentTarget(
        in state: ClaudeSessionState,
        in context: ClaudeMicroContext
    ) -> ClaudeSlotTarget? {
        context.board.slots.enumerated()
            .compactMap { offset, slot in
                slot.map { ClaudeSlotTarget(index: offset, slot: $0) }
            }
            .filter { $0.slot.record.host == context.host && $0.slot.state == state }
            .max { $0.slot.record.updatedAt < $1.slot.record.updatedAt }
    }
}

struct ClaudeMicroOutcome: Equatable, Sendable {
    let log: String
    let openedSlot: Int?
    let index: ClaudeDesktopIndex
}

@MainActor
struct ClaudeMicroActions {
    private let planner = ClaudeMicroActionPlanner()
    private let links = ClaudeSessionLinks()
    private let t3Links = T3SessionLinks()
    private let app: ClaudeAppControlling
    private let desktopStore: ClaudeDesktopSessionStore

    init(
        app: ClaudeAppControlling,
        desktopStore: ClaudeDesktopSessionStore
    ) {
        self.app = app
        self.desktopStore = desktopStore
    }

    func perform(
        _ press: MicroPress,
        on board: ClaudeSlotBoard,
        host: ClaudeSessionHost,
        index: ClaudeDesktopIndex
    ) -> ClaudeMicroOutcome {
        let context = ClaudeMicroContext(
            host: host,
            board: board,
            focusedSessionID: index.focusedCLISessionID,
            frontmost: app.frontmostApplication()
        )
        switch planner.plan(for: press, in: context) {
        case .openNewTask:
            let url = host == .t3Code ? T3SessionLinks.newThread : ClaudeSessionLinks.newTask
            return openLink(url, for: press, index: index)
        case .openWaiting:
            return openLink(ClaudeSessionLinks.waiting, for: press, index: index)
        case .openSlot(let target):
            return openSlot(
                target,
                for: press,
                because: nil,
                index: index
            )
        case .redirect(let target, let fallback):
            return openSlot(
                target,
                for: press,
                because: fallback,
                index: index
            )
        case .send(let keystroke, let processIdentifier):
            return send(
                keystroke,
                toProcess: processIdentifier,
                for: press,
                index: index
            )
        case .ignore(let reason):
            return ClaudeMicroOutcome(
                log: "\(press.keyName) ignored: \(describe(reason))",
                openedSlot: nil,
                index: index
            )
        }
    }

    private func openLink(
        _ url: URL,
        for press: MicroPress,
        index: ClaudeDesktopIndex
    ) -> ClaudeMicroOutcome {
        app.open(url)
        return ClaudeMicroOutcome(
            log: "\(press.keyName) opened \(url.absoluteString)",
            openedSlot: nil,
            index: index
        )
    }

    private func openSlot(
        _ target: ClaudeSlotTarget,
        for press: MicroPress,
        because fallback: ClaudeMicroFallback?,
        index: ClaudeDesktopIndex
    ) -> ClaudeMicroOutcome {
        switch target.slot.record.host {
        case .t3Code:
            return openT3Thread(target, for: press, because: fallback, index: index)
        case .claudeDesktop:
            break
        }
        let resolution = desktopStore.resolving(
            target.slot.record.sessionID,
            in: index
        )
        guard let url = links.url(for: target.slot, localID: resolution.localID) else {
            return ClaudeMicroOutcome(
                log: "\(press.keyName) ignored: no link for slot \(target.index)",
                openedSlot: nil,
                index: resolution.index
            )
        }
        app.open(url)
        let unmatched = resolution.localID == nil ? " (no Claude session match)" : ""
        let reason = fallback.map { ", no key sent: \(describe($0))" } ?? ""
        return ClaudeMicroOutcome(
            log: "\(press.keyName) opened \(url.absoluteString)\(unmatched)\(reason)",
            openedSlot: target.index,
            index: resolution.index
        )
    }

    private func openT3Thread(
        _ target: ClaudeSlotTarget,
        for press: MicroPress,
        because fallback: ClaudeMicroFallback?,
        index: ClaudeDesktopIndex
    ) -> ClaudeMicroOutcome {
        let reason = fallback.map { ", no key sent: \(describe($0))" } ?? ""
        if let url = t3Links.url(for: target.slot.record) {
            app.open(url)
            return ClaudeMicroOutcome(
                log: "\(press.keyName) opened \(url.absoluteString)\(reason)",
                openedSlot: target.index,
                index: index
            )
        }
        guard app.activateT3Code() else {
            return ClaudeMicroOutcome(
                log: "\(press.keyName) ignored: T3 Code is not installed or could not be opened",
                openedSlot: nil,
                index: index
            )
        }
        let thread = target.slot.record.threadID.map { " (thread \($0))" } ?? ""
        return ClaudeMicroOutcome(
            log: "\(press.keyName) activated T3 Code for slot \(target.index)\(thread)\(reason)",
            openedSlot: target.index,
            index: index
        )
    }

    private func send(
        _ keystroke: ClaudeKeystroke,
        toProcess processIdentifier: pid_t,
        for press: MicroPress,
        index: ClaudeDesktopIndex
    ) -> ClaudeMicroOutcome {
        let posted = app.post(keystroke, toProcess: processIdentifier)
        let result = posted
            ? "sent \(keystroke.rawValue) to Claude"
            : "ignored: could not post \(keystroke.rawValue) to Claude"
        return ClaudeMicroOutcome(
            log: "\(press.keyName) \(result)",
            openedSlot: nil,
            index: index
        )
    }

    private func describe(_ reason: ClaudeMicroIgnoreReason) -> String {
        switch reason {
        case .emptySlot: "slot is empty"
        case .noSession(let state): "no session is \(state.rawValue)"
        case .nothingWaiting: "no session is waiting"
        }
    }

    private func describe(_ fallback: ClaudeMicroFallback) -> String {
        switch fallback {
        case .claudeNotFrontmost: "Claude is not frontmost"
        case .focusedSessionNotOnBoard: "focused session is not on the board"
        case .focusedSessionNotIn(let state): "focused session is not \(state.rawValue)"
        case .t3HasNoShortcut: "T3 Code has no shortcut for this key"
        }
    }
}
