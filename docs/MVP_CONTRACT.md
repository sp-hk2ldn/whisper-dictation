# MVP Contract

The first shippable version has one success path:

1. Hold the configured global hotkey.
2. Capture microphone audio locally.
3. Release the hotkey.
4. Produce one final WhisperKit transcript from the frozen audio.
5. Revalidate the application and text target captured at key-down.
6. Insert the transcript exactly once without activating another app.

Partials may be shown in the HUD but never modify another application.

## Safety invariants

- A cancelled or superseded session never inserts text.
- A changed, missing, secure, or read-only target never receives text.
- Paste fallback events are posted only after revalidating the captured process
  and exact focused Accessibility element.
- A successful Accessibility write is never retried through another adapter,
  even when the destination does not expose a readable value for confirmation.
- Terminal insertion never contains carriage return, line feed, tab, or another
  control character.
- No insertion adapter generates Return or keypad Enter.
- Paste fallback snapshots every clipboard item and type, restores them after
  posting, and never overwrites a clipboard changed concurrently by the user.
- Audio and transcripts remain local and are not logged or retained by default.
- A hotkey never initiates a permission prompt or model download.
- Permission prompts and model download are explicit Settings actions only.

## Replaceable boundaries

- `HotkeySource`
- `AudioCapturing`
- `Transcribing`
- `TargetTracking`
- `TextInserting`

`DictationSessionCoordinator` is the only owner of the session lifecycle. Live
macOS and WhisperKit implementations sit behind these boundaries.
