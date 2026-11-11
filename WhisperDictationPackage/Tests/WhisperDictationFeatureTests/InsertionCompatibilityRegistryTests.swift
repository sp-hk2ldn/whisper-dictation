import Testing
@testable import WhisperDictationFeature

struct InsertionCompatibilityRegistryTests {
    @Test
    func routesKnownOverridesAndDefaultsByCapability() {
        let codexProfile = InsertionCompatibilityRegistry.profile(
            for: KnownTextDestination.codex.rawValue
        )
        #expect(codexProfile.route == .pasteOnly)
        #expect(codexProfile.pasteboardRestoreDelay == .seconds(2))

        let unknownProfile = InsertionCompatibilityRegistry.profile(
            for: "com.example.unknown"
        )
        #expect(unknownProfile.route == .accessibilityThenPaste)
        #expect(
            unknownProfile.pasteboardRestoreDelay == .milliseconds(300)
        )

        let nilProfile = InsertionCompatibilityRegistry.profile(for: nil)
        #expect(nilProfile == unknownProfile)
    }

    @Test
    func hermesRoutesThroughPasteOnly() {
        // Hermes is a Chromium / Electron / CodeMirror app that exposes
        // its focused contenteditable as `AXGroup` rather than an
        // `AXTextArea`. Capture falls back to the focused window; the
        // paste-only route skips the AX-set attempt and gives Chromium
        // enough time to consume the pasteboard change.
        let hermesProfile = InsertionCompatibilityRegistry.profile(
            for: KnownTextDestination.hermes.rawValue
        )
        #expect(hermesProfile.route == .pasteOnly)
        #expect(
            hermesProfile.pasteboardRestoreDelay == .milliseconds(1500)
        )
        #expect(
            KnownTextDestination(rawValue: "com.nousresearch.hermes")
                == .hermes
        )
    }

    @Test
    func claudeDesktopRoutesThroughPasteOnly() {
        let claudeProfile = InsertionCompatibilityRegistry.profile(
            for: "com.anthropic.claudefordesktop"
        )
        #expect(claudeProfile.route == .pasteOnly)
    }

    @Test
    func t3CodeRoutesThroughPasteOnly() {
        let t3Profile = InsertionCompatibilityRegistry.profile(
            for: "com.t3tools.t3code"
        )
        #expect(t3Profile.route == .pasteOnly)
    }

    @Test
    func pasteOnlyRestoreDelayIsSlowerThanDefault() {
        // Chromium-based apps need more time than the default 300ms to
        // consume a pasteboard change and route it to the contenteditable's
        // DOM focus. Both known paste-only destinations should be slower
        // than the default.
        let defaultProfile = InsertionCompatibilityRegistry.profile(
            for: nil
        )
        let codexProfile = InsertionCompatibilityRegistry.profile(
            for: KnownTextDestination.codex.rawValue
        )
        let hermesProfile = InsertionCompatibilityRegistry.profile(
            for: KnownTextDestination.hermes.rawValue
        )
        let defaultDelayNs = defaultProfile.pasteboardRestoreDelay
            .components.seconds * 1_000_000_000
            + Int64(defaultProfile.pasteboardRestoreDelay.components.attoseconds / 1_000_000_000)
        let codexDelayNs = codexProfile.pasteboardRestoreDelay
            .components.seconds * 1_000_000_000
            + Int64(codexProfile.pasteboardRestoreDelay.components.attoseconds / 1_000_000_000)
        let hermesDelayNs = hermesProfile.pasteboardRestoreDelay
            .components.seconds * 1_000_000_000
            + Int64(hermesProfile.pasteboardRestoreDelay.components.attoseconds / 1_000_000_000)
        #expect(codexDelayNs > defaultDelayNs)
        #expect(hermesDelayNs > defaultDelayNs)
    }
}
