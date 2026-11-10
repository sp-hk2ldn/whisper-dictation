import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

public actor MacTextInsertionService: TargetTracking, TextInserting {
    private enum PasteResult: Equatable {
        case postedAndRestored
        case postedClipboardChanged
        case unavailable
    }

    private struct Snapshot {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        var element: AXUIElement
        let fingerprint: ElementFingerprint
        let isFallback: Bool
    }

    private struct ElementFingerprint {
        let role: String
        let subrole: String?
        let identifier: String?
        let position: CGPoint?
        let size: CGSize?
        let window: AXUIElement?
        let windowTitle: String?
        let windowPosition: CGPoint?
        let windowSize: CGSize?
    }

    private var snapshots: [UUID: Snapshot] = [:]
    private var diagnostic = "not-started"

    public init() {}

    public nonisolated var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public nonisolated func requestAccessibilityPermission() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func releaseTarget(_ token: TargetToken) async {
        snapshots[token.id] = nil
    }

    public func captureTarget() async -> TargetToken? {
        guard AXIsProcessTrusted() else {
            diagnostic = "capture accessibility-denied"
            return nil
        }

        let applicationIdentity: (pid_t, String?)? = await MainActor.run {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            return (application.processIdentifier, application.bundleIdentifier)
        }

        guard let (processIdentifier, bundleIdentifier) = applicationIdentity else {
            diagnostic = "capture no-frontmost-application"
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let element = await focusedElementAfterEnablingElectronAccessibility(
            copyElement(attribute: kAXFocusedUIElementAttribute, from: applicationElement),
            in: applicationElement
        )
        let focusedWindow = copyElement(
            attribute: kAXFocusedWindowAttribute,
            from: applicationElement
        )
        if let element,
           stringAttribute(kAXSubroleAttribute, from: element)?
            .localizedCaseInsensitiveContains("secure") == true {
            diagnostic = "capture secure-field"
            return nil
        }
        let direct = element.flatMap { isDirectTextTarget($0) ? $0 : nil }
        let windowSearch = direct == nil ? focusedWindow.map { inputSearch(in: $0) } : nil
        let fallback = windowSearch?.uniqueCandidate
        let resolvedElement = direct ?? fallback ?? element.flatMap {
            Self.isTerminal(bundleIdentifier) ? resolveCaptureElement(focusedElement: $0, fallbackWindow: focusedWindow,
                                  bundleIdentifier: bundleIdentifier) : nil
        }
        guard let resolvedElement else {
            let focusedRole = element.flatMap { stringAttribute(kAXRoleAttribute, from: $0) }
            diagnostic = "capture no-unambiguous-input "
                + "at=\(Date.now.formatted(.iso8601)) "
                + "app=\(bundleIdentifier ?? "pid:\(processIdentifier)") "
                + "focused=\(focusedRole ?? "none") "
                + textBoxSummary(windowSearch)
            return nil
        }

        let kind: TargetKind = Self.isTerminal(bundleIdentifier)
            ? .terminal
            : .standard
        guard
            let fingerprint = fingerprint(
                for: resolvedElement,
                fallbackWindow: focusedWindow
            )
        else {
            diagnostic = "capture no-stable-fingerprint"
            return nil
        }
        let token = TargetToken(kind: kind)
        snapshots[token.id] = Snapshot(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            element: resolvedElement,
            fingerprint: fingerprint,
            isFallback: fallback != nil
        )
        diagnostic = "capture ready kind=\(kind) "
            + "app=\(bundleIdentifier ?? "pid:\(processIdentifier)") "
            + "role=\(fingerprint.role)"
        return token
    }

    public func diagnosticSummary() -> String {
        diagnostic
    }

    public func isStillValid(_ token: TargetToken) async -> Bool {
        guard AXIsProcessTrusted() else {
            diagnostic = "validate accessibility-denied"
            snapshots[token.id] = nil
            return false
        }
        guard var snapshot = snapshots[token.id] else {
            diagnostic = "validate snapshot-missing"
            return false
        }

        let frontmostApplication: (pid_t, String?)? = await MainActor.run {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            return (
                application.processIdentifier,
                application.bundleIdentifier
            )
        }
        guard frontmostApplication?.0 == snapshot.processIdentifier else {
            let expectedApplication = snapshot.bundleIdentifier
                ?? "pid:\(snapshot.processIdentifier)"
            let actualApplication = frontmostApplication?.1
                ?? frontmostApplication.map { "pid:\($0.0)" }
                ?? "none"
            diagnostic = "validate frontmost-process-changed "
                + "expected=\(expectedApplication) "
                + "actual=\(actualApplication)"
            snapshots[token.id] = nil
            return false
        }

        let applicationElement = AXUIElementCreateApplication(snapshot.processIdentifier)
        let focusedWindow = copyElement(
            attribute: kAXFocusedWindowAttribute,
            from: applicationElement
        )

        if snapshot.isFallback {
            guard let focusedWindow, let originalWindow = snapshot.fingerprint.window,
                  CFEqual(focusedWindow, originalWindow),
                  let candidate = uniqueInput(in: focusedWindow),
                  CFEqual(candidate, snapshot.element) else {
                diagnostic = "validate fallback-window-or-input-changed"
                return false
            }
            let current = copyElement(attribute: kAXFocusedUIElementAttribute, from: applicationElement)
            if let current, !CFEqual(current, candidate), isDirectTextTarget(current) {
                diagnostic = "validate fallback-another-input-focused"
                return false
            }
            if current.map({ CFEqual($0, candidate) }) != true {
                guard AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString,
                                                   kCFBooleanTrue) == .success,
                      let focused = copyElement(attribute: kAXFocusedUIElementAttribute,
                                                from: applicationElement),
                      CFEqual(focused, candidate) else {
                    diagnostic = "validate fallback-focus-failed"
                    return false
                }
            }
            diagnostic = "validate fallback-ready"
            return true
        }

        let isPasteOnly = InsertionCompatibilityRegistry.profile(
            for: snapshot.bundleIdentifier
        ).route == .pasteOnly

        guard
            let currentElement = copyElement(
                attribute: kAXFocusedUIElementAttribute,
                from: applicationElement
            )
        else {
            diagnostic = "validate no-focused-element"
            snapshots[token.id] = nil
            return false
        }
        // For paste-only destinations the captured element may be the
        // focused window (Chromium / Electron wrappers expose the focused
        // element as `AXGroup`, not a text container). Relax the role
        // check so we don't refuse a still-valid Hermes session.
        if !isPasteOnly {
            guard isEligibleTextTarget(currentElement) else {
                diagnostic = "validate focused-element-not-editable"
                snapshots[token.id] = nil
                return false
            }
        }
        guard
            CFEqual(currentElement, snapshot.element)
                || (isPasteOnly
                    && pasteOnlyWindowMatches(
                        currentElement: currentElement,
                        snapshot: snapshot,
                        focusedWindow: focusedWindow
                    ))
                || matches(
                    currentElement,
                    fingerprint: snapshot.fingerprint,
                    fallbackWindow: focusedWindow
                )
        else {
            diagnostic = "validate target-fingerprint-changed"
            snapshots[token.id] = nil
            return false
        }

        snapshot.element = currentElement
        snapshots[token.id] = snapshot
        diagnostic = "validate ready"
        return true
    }

    public func insert(
        _ text: SafeInsertionText,
        into target: TargetToken,
        sessionID: UUID
    ) async -> InsertionResult {
        guard !text.value.isEmpty else {
            diagnostic = "insert refused-empty-text"
            return .refused
        }
        guard await isStillValid(target) else {
            diagnostic = "insert refused-\(diagnostic)"
            return .refused
        }
        guard let snapshot = snapshots[target.id] else {
            diagnostic = "insert refused-snapshot-missing"
            return .refused
        }

        defer {
            snapshots[target.id] = nil
        }

        let targetDescription = "app="
            + (snapshot.bundleIdentifier ?? "pid:\(snapshot.processIdentifier)")
            + " role=\(snapshot.fingerprint.role)"
        var fallbackReason: String
        let compatibilityProfile = InsertionCompatibilityRegistry.profile(
            for: snapshot.bundleIdentifier
        )
        if compatibilityProfile.route == .pasteOnly {
            fallbackReason = "ax-skipped-incompatible-target"
        } else if canSetSelectedText(on: snapshot.element) {
            let error = AXUIElementSetAttributeValue(
                snapshot.element,
                kAXSelectedTextAttribute as CFString,
                text.value as CFString
            )
            if error == .success {
                let value = stringAttribute(
                    kAXValueAttribute,
                    from: snapshot.element
                )
                if value?.contains(text.value) == true {
                    diagnostic = "insert ax-confirmed \(targetDescription)"
                } else {
                    // A successful AX mutation is authoritative even when a
                    // rich-text control does not expose a readable AXValue.
                    // Retrying through CGEvent here could insert the same
                    // transcript twice.
                    diagnostic = "insert ax-success-unconfirmed "
                        + targetDescription
                }
                return .inserted
            } else {
                fallbackReason = "ax-error-\(error.rawValue)"
            }
        } else {
            fallbackReason = "ax-not-settable"
        }

        guard await isStillValid(target) else {
            diagnostic += " fallback-refused-invalid-target"
            return .refused
        }

        let pasteResult = await pasteText(
            text.value,
            targetProcessIdentifier: snapshot.processIdentifier,
            restoreDelay: compatibilityProfile.pasteboardRestoreDelay
        )
        switch pasteResult {
        case .postedAndRestored, .postedClipboardChanged:
            let insertionDiagnostic = "insert \(fallbackReason) "
                + "fallback-paste \(targetDescription)"
            if
                await isStillValid(target),
                let currentSnapshot = snapshots[target.id],
                stringAttribute(
                    kAXValueAttribute,
                    from: currentSnapshot.element
                )?.contains(text.value) == true
            {
                diagnostic = insertionDiagnostic + "-confirmed"
            } else {
                let clipboardState = pasteResult == .postedAndRestored
                    ? "clipboard-restored"
                    : "clipboard-changed-by-user"
                diagnostic = insertionDiagnostic
                    + "-posted-unconfirmed-\(clipboardState)"
            }
            return .inserted
        case .unavailable:
            diagnostic = "insert \(fallbackReason) "
                + "fallback-paste-unavailable \(targetDescription)"
            return .refused
        }
    }

    private func uniqueInput(in window: AXUIElement) -> AXUIElement? {
        inputSearch(in: window).uniqueCandidate
    }

    private func textBoxSummary(_ search: FallbackFieldSearchResult<AXUIElement>?) -> String {
        switch search {
        case .complete(let candidates):
            "window-text-boxes=\(candidates.count)"
        case .incomplete(let candidatesFound):
            "window-text-boxes>=\(candidatesFound) search-incomplete"
        case nil:
            "window=none"
        }
    }

    private func inputSearch(in window: AXUIElement) -> FallbackFieldSearchResult<AXUIElement> {
        let deadline = ContinuousClock.now + .milliseconds(150)
        var exhausted = false
        let result = FallbackFieldSearch.search(root: window, children: { element in
            guard ContinuousClock.now < deadline else { exhausted = true; return [] }
            AXUIElementSetMessagingTimeout(element, 0.02)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if result == .attributeUnsupported || result == .noValue { return [] }
            guard result == .success else { exhausted = true; return [] }
            return value as? [AXUIElement] ?? []
        }, isCandidate: { element in
            guard ContinuousClock.now < deadline else { exhausted = true; return false }
            AXUIElementSetMessagingTimeout(element, 0.02)
            let role = stringAttribute(kAXRoleAttribute, from: element)
            guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
                  isEligibleTextTarget(element),
                  boolAttribute(kAXEnabledAttribute, from: element) == true,
                  boolAttribute("AXHidden", from: element) != true,
                  let position = pointAttribute(kAXPositionAttribute, from: element),
                  let size = sizeAttribute(kAXSizeAttribute, from: element),
                  size.width > 0, size.height > 0,
                  let windowPosition = pointAttribute(kAXPositionAttribute, from: window),
                  let windowSize = sizeAttribute(kAXSizeAttribute, from: window),
                  CGRect(origin: windowPosition, size: windowSize)
                    .intersects(CGRect(origin: position, size: size)) else { return false }
            var focusSettable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString,
                                                  &focusSettable) == .success && focusSettable.boolValue
        })
        guard exhausted, case .complete(let candidates) = result else { return result }
        return .incomplete(candidatesFound: candidates.count)
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func copyElement(
        attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )

        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )

        guard error == .success else { return nil }
        return value as? String
    }

    private func pointAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard
            error == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard
            error == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func fingerprint(
        for element: AXUIElement,
        fallbackWindow: AXUIElement?
    ) -> ElementFingerprint? {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else {
            return nil
        }

        let window = copyElement(
            attribute: kAXWindowAttribute,
            from: element
        ) ?? fallbackWindow
        return ElementFingerprint(
            role: role,
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            identifier: stringAttribute(kAXIdentifierAttribute, from: element),
            position: pointAttribute(kAXPositionAttribute, from: element),
            size: sizeAttribute(kAXSizeAttribute, from: element),
            window: window,
            windowTitle: window.flatMap {
                stringAttribute(kAXTitleAttribute, from: $0)
            },
            windowPosition: window.flatMap {
                pointAttribute(kAXPositionAttribute, from: $0)
            },
            windowSize: window.flatMap {
                sizeAttribute(kAXSizeAttribute, from: $0)
            }
        )
    }

    private func matches(
        _ element: AXUIElement,
        fingerprint: ElementFingerprint,
        fallbackWindow: AXUIElement?
    ) -> Bool {
        guard
            stringAttribute(kAXRoleAttribute, from: element)
                == fingerprint.role,
            stringAttribute(kAXSubroleAttribute, from: element)
                == fingerprint.subrole,
            matchesWindow(
                element,
                fingerprint: fingerprint,
                fallbackWindow: fallbackWindow
            )
        else {
            return false
        }

        if
            let identifier = fingerprint.identifier,
            !identifier.isEmpty,
            stringAttribute(kAXIdentifierAttribute, from: element)
                == identifier
        {
            return true
        }

        guard
            let position = fingerprint.position,
            let size = fingerprint.size,
            let currentPosition = pointAttribute(
                kAXPositionAttribute,
                from: element
            ),
            let currentSize = sizeAttribute(kAXSizeAttribute, from: element)
        else {
            return false
        }

        return approximatelyEqual(position, currentPosition)
            && approximatelyEqual(size, currentSize)
    }

    private func matchesWindow(
        _ element: AXUIElement,
        fingerprint: ElementFingerprint,
        fallbackWindow: AXUIElement?
    ) -> Bool {
        guard
            let expectedWindow = fingerprint.window,
            let currentWindow = copyElement(
                attribute: kAXWindowAttribute,
                from: element
            ) ?? fallbackWindow
        else {
            return false
        }
        if CFEqual(currentWindow, expectedWindow) {
            return true
        }

        guard
            let title = fingerprint.windowTitle,
            !title.isEmpty,
            stringAttribute(kAXTitleAttribute, from: currentWindow) == title,
            let position = fingerprint.windowPosition,
            let size = fingerprint.windowSize,
            let currentPosition = pointAttribute(
                kAXPositionAttribute,
                from: currentWindow
            ),
            let currentSize = sizeAttribute(
                kAXSizeAttribute,
                from: currentWindow
            )
        else {
            return false
        }

        return approximatelyEqual(position, currentPosition)
            && approximatelyEqual(size, currentSize)
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func resolveCaptureElement(
        focusedElement: AXUIElement,
        fallbackWindow: AXUIElement?,
        bundleIdentifier: String?
    ) -> AXUIElement? {
        if isEligibleTextTarget(focusedElement) {
            return focusedElement
        }

        // Paste-only destinations (Chromium / Electron wrappers) may expose
        // the focused element as `AXGroup` rather than an `AXTextArea`. The
        // AX-set path is skipped for these destinations, so we only need a
        // stable token for revalidation. Fall back to the focused window,
        // which provides a stable title / position / size fingerprint across
        // the transcription window.
        guard
            InsertionCompatibilityRegistry.profile(
                for: bundleIdentifier
            ).route == .pasteOnly
        else {
            return nil
        }

        if
            let role = stringAttribute(
                kAXRoleAttribute,
                from: fallbackWindow ?? focusedElement
            ),
            Self.pasteOnlyEligibleRoles.contains(role)
        {
            return fallbackWindow ?? focusedElement
        }
        return nil
    }

    private func isEligibleTextTarget(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)

        guard subrole?.localizedCaseInsensitiveContains("secure") != true else {
            return false
        }

        let supportedRoles: [String] = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
            "AXWebArea",
        ]
        return role.map(supportedRoles.contains) ?? false
    }

    private func isDirectTextTarget(_ element: AXUIElement) -> Bool {
        isEligibleTextTarget(element)
            && stringAttribute(kAXRoleAttribute, from: element) != "AXWebArea"
    }

    // Electron apps such as Claude build their full accessibility tree only
    // after an assistive app sets AXManualAccessibility on the application.
    private func focusedElementAfterEnablingElectronAccessibility(
        _ focusedElement: AXUIElement?,
        in applicationElement: AXUIElement
    ) async -> AXUIElement? {
        guard
            focusedElement.map(isDirectTextTarget) != true,
            AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            ) == .success
        else {
            return focusedElement
        }
        try? await Task.sleep(for: Self.electronAccessibilityBuildDelay)
        return copyElement(attribute: kAXFocusedUIElementAttribute, from: applicationElement)
    }

    private static let electronAccessibilityBuildDelay = Duration.milliseconds(250)

    /// Roles accepted as a capture target *only* when the destination is
    /// routed through the paste fallback (Chromium / Electron wrappers).
    /// The AX-set path is skipped for these destinations, so we only need
    /// a stable token for revalidation; the window itself has a stable
    /// title / position / size fingerprint that does not jiggle when
    /// Chromium re-creates a contenteditable subtree.
    private static let pasteOnlyEligibleRoles: [String] = [
        "AXWindow",
        "AXGroup",
    ]

    /// Window-only fingerprint match used for paste-only destinations.
    /// Chromium / Electron wrappers expose the focused element as `AXGroup`
    /// and re-create the contenteditable subtree on every reflow, so an
    /// element-level fingerprint would always mismatch. The window itself
    /// (title / position / size) is stable across the transcription
    /// window, which is enough to confirm "same window, same process".
    private func pasteOnlyWindowMatches(
        currentElement: AXUIElement,
        snapshot: Snapshot,
        focusedWindow: AXUIElement?
    ) -> Bool {
        guard let snapshotWindow = snapshot.fingerprint.window else {
            return false
        }
        let currentWindow = copyElement(
            attribute: kAXWindowAttribute,
            from: currentElement
        ) ?? focusedWindow
        guard let currentWindow else { return false }
        if CFEqual(currentWindow, snapshotWindow) { return true }

        // Fall back to a stronger window-identity match: same title and
        // approximately the same position and size.
        return matchesWindow(
            currentElement,
            fingerprint: snapshot.fingerprint,
            fallbackWindow: currentWindow
        )
    }

    private func canSetSelectedText(on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        return error == .success && settable.boolValue
    }

    private func pasteText(
        _ text: String,
        targetProcessIdentifier: pid_t,
        restoreDelay: Duration
    ) async -> PasteResult {
        guard
            let transaction = await beginPasteboardTransaction(text: text)
        else {
            return .unavailable
        }

        guard postPasteShortcut(to: targetProcessIdentifier) else {
            _ = await restorePasteboard(transaction)
            return .unavailable
        }

        try? await Task.sleep(for: restoreDelay)
        return await restorePasteboard(transaction)
            ? .postedAndRestored
            : .postedClipboardChanged
    }

    private func beginPasteboardTransaction(
        text: String
    ) async -> PasteboardTransaction? {
        await MainActor.run {
            PasteboardTransactionStore.begin(
                text: text,
                on: .general
            )
        }
    }

    private func restorePasteboard(
        _ transaction: PasteboardTransaction
    ) async -> Bool {
        await MainActor.run {
            PasteboardTransactionStore.restore(
                transaction,
                on: .general
            )
        }
    }

    private func postPasteShortcut(to processIdentifier: pid_t) -> Bool {
        guard
            AXIsProcessTrusted(),
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }

    private static func isTerminal(_ bundleIdentifier: String?) -> Bool {
        switch bundleIdentifier {
        case "com.apple.Terminal", "com.mitchellh.ghostty":
            true
        default:
            false
        }
    }

}
