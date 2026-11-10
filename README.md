# Whisper Dictation

> Native, private push-to-talk dictation for macOS, powered entirely on-device
> by WhisperKit and OpenAI Whisper large-v3.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-first-555555)
![Swift 6.1](https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white)
![Local only](https://img.shields.io/badge/transcription-local%20only-2ea44f)

Whisper Dictation is a lightweight macOS menu-bar utility. Hold a global
shortcut, speak naturally, then release it. The app transcribes the recording
locally and inserts the result at the cursor that was focused when recording
began—even in another application.

The MVP has no account, subscription, cloud transcription, telemetry, or
helper server. Audio and transcripts stay on the Mac, and the app never presses
Return.

## Why it exists

macOS dictation is convenient, but it is tied to system behavior and does not
offer a small, inspectable Whisper pipeline. Whisper Dictation is deliberately
narrow: one global push-to-talk gesture, one local final transcript, and one
safe insertion into the originating text field.

The project prioritizes:

- privacy by architecture rather than by account settings
- reliable dictation across native, web, Electron, and terminal text fields
- explicit focus validation before any text is inserted
- zero accidental terminal command execution
- replaceable adapters instead of a background server or heavyweight framework

## MVP behavior

- macOS 14 or newer on Apple Silicon
- SwiftUI menu-bar shell with AppKit/Carbon/AVFoundation adapters
- configurable push-to-talk shortcuts; default: `⌃⌥⌘ Space`
- local final transcription after key-up
- exact focus revalidation before insertion
- AX selected-text insertion with clipboard-restoring paste as fallback
- terminal sanitization that removes Return, line feed, tab, and control bytes
- explicit recovery text when the original target is no longer safe

Partials are not inserted in the MVP. This avoids corrupting text when Whisper
revises an unstable partial hypothesis.

## Speech-to-text model

The app currently uses:

| Layer | Selection |
| --- | --- |
| Speech model | OpenAI Whisper `large-v3` |
| Apple deployment | Argmax `large-v3-v20240930_626MB` Core ML bundle |
| Runtime | WhisperKit `1.0.0` |
| Pinned revision | `25c62997041c134b03ca82731ce2f6fd2cae1eb9` |
| Model repository | `argmaxinc/whisperkit-coreml` |
| Local footprint | Approximately 600 MB including the compiled model and tokenizer |
| Input | 16 kHz, mono, `Float32` PCM |
| Decode mode | Final English transcription, temperature `0`, language detection disabled |

### What the model is

[Whisper large-v3](https://github.com/openai/whisper) is OpenAI's multilingual
1.55-billion-parameter sequence-to-sequence speech model. It converts audio
into text and can identify the spoken language. This app is intentionally
English-only: it selects transcription, not speech translation, and skips the
language-detection pass.

The app does not ship PyTorch weights or call an OpenAI service. It downloads
Argmax's [`large-v3-v20240930_626MB`](https://huggingface.co/argmaxinc/whisperkit-coreml)
deployment of large-v3, converted for Apple's Core ML runtime. WhisperKit splits
the local pipeline into compiled `MelSpectrogram`, `AudioEncoder`, and
`TextDecoder` model components, plus the Whisper large-v3 tokenizer. Core ML and
WhisperKit choose the available Apple-silicon compute resources; this project
does not hard-code a particular CPU, GPU, or Neural Engine allocation.

### Why this variant

Argmax recommends `large-v3-v20240930_626MB` for maximum multilingual accuracy.
For dictation, its quality is worth the larger disk and memory footprint:
punctuation, natural phrasing, accents, and mixed vocabulary matter more than
the smallest possible model. The model boundary is isolated, so a smaller or
faster WhisperKit-compatible model can be introduced later without changing
audio capture, focus tracking, or insertion.

### Exact inference behavior

1. `AVAudioEngine` captures the current microphone without an always-running
   audio service.
2. `AudioPCMNormalizer` converts the captured buffer to WhisperKit's required
   16 kHz mono floating-point samples.
3. On key-up, the frozen utterance is decoded once with `task: .transcribe`,
   language `en`, `temperature: 0`, language detection disabled, special tokens removed, and
   word timestamps disabled.
4. Segment text is joined and trimmed. An empty result is treated as “no speech
   detected,” not inserted as a successful dictation.
5. The coordinator performs exactly one final insertion attempt for the active
   session.

The model is downloaded only when the user presses **Download Local Model** in
Settings. The app never downloads a missing model during dictation. After the
download, inference works with network access denied. The cache lives at:

```text
~/Library/Application Support/WhisperDictation/Models
```

It is excluded from backups. The model is loaded lazily into the process and is
reused for warm dictations; the MVP keeps it loaded until the app exits.

## Codex Micro lighting

> **Unofficial.** The Codex Micro is made by Work Louder for OpenAI. Neither
> publishes its HID protocol. The commands Whisper Dictation sends were worked
> out by observation, are not affiliated with or endorsed by OpenAI or Work
> Louder, and may stop working after a firmware or Codex update.

The **Codex Micro lighting** switch in the menu drives the Micro's ambient ring
with Codex's colors while you dictate: a snaking green (`0x2E8B57`) while
recording, a snaking white while transcribing and inserting, and a solid white
ring briefly after insertion. A new recording takes priority immediately. When
dictation finishes the ring goes back to the Claude session picture described
below, and every light turns off when the switch is disabled or the app quits.
Existing key mappings are unchanged.

Lighting uses a native USB/Bluetooth HID connection on a separate queue, with
state updates coalesced so accessory delays cannot block recording or insertion.
If macOS denies access, the menu offers **Enable Input Monitoring…** for the
installed Whisper Dictation app. Deterministic dictation smoke runs disable
hardware lighting. Codex can also update these lights; Whisper does not
continuously repaint to override it. The indicator clears to off rather
than restoring another application's previous colors.

## Claude session lighting

With **Codex Micro lighting** on, Whisper Dictation also drives the Micro's six
slot lights and ambient ring for Claude Code sessions, the way Codex.app did for
Codex threads. Dictation uses the ring colors below.

### Hooks

`integrations/claude-code/claude-micro-hook.sh STATE` is a Claude Code hook
command. It reads the hook JSON on stdin and records sessions with
`CLAUDE_CODE_ENTRYPOINT` equal to `claude-desktop` (the Claude desktop app) or
`t3-code` (T3 Code); sessions in a terminal or any other host are ignored. It
writes `{state, cwd, updatedAt, host}` to
`~/Library/Application Support/Whisper Dictation/claude-sessions/<session_id>.json`.
`host` is `claude-desktop` or `t3-code`; old files without it are treated as
Claude desktop. Unknown hosts are invalid. T3 records also include `threadID`
from `T3CODE_THREAD_ID` and `environmentID` from
`${T3CODE_HOME:-~/.t3}/userdata/environment-id`; each is written only when it
matches `^[A-Za-z0-9._-]+$`. State `ended` deletes the file. It prints nothing
and always exits 0.

To install it:

```sh
mkdir -p ~/.claude/hooks
cp integrations/claude-code/claude-micro-hook.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/claude-micro-hook.sh
```

Then merge the `hooks` entries from
[`integrations/claude-code/settings.json`](integrations/claude-code/settings.json)
into `~/.claude/settings.json`. T3 Code runs Claude Code with the same user
settings, so the same entries cover T3 sessions. If you already have hooks for
an event, add these entries to that event's list rather than replacing it. The
entries are:

| Hook event | Matcher | STATE |
| --- | --- | --- |
| `SessionStart` | | `idle` |
| `UserPromptSubmit` | | `working` |
| `PostToolUse` | | `working` |
| `PermissionDenied` | | `working` |
| `PreToolUse` | `AskUserQuestion` | `awaiting-response` |
| `PermissionRequest` | | `awaiting-approval` |
| `Notification` | `permission_prompt` | `awaiting-approval` |
| `Notification` | `elicitation_dialog` | `awaiting-response` |
| `Stop` | | `unread` |
| `StopFailure` | | `error` |
| `SessionEnd` | | `ended` |

### Slots

The app watches that folder and rescans it at launch. A session keeps its slot
until it ends. A new session takes the lowest free slot. When all six are taken
it replaces the least recently updated idle or unread session, and a new session
waits if every slot is busy. Files older than 24 hours are dropped and deleted.
The selected session is the one most recently focused in the Claude desktop app
(the highest `lastFocusedAt`), when it is on the board, so focusing a session in
Claude moves the selection. A slot key press also selects its slot. When the
focused session is not on the board, the selected session is the one that most
recently started working. Its slot breathes for 4 seconds after the selection
changes, then goes back to solid.

| Slot state | Color |
| --- | --- |
| Working | `0x304FFE` |
| Unread (finished, not yet looked at) | `0x00FF4C` |
| Idle | `0xFFFFFF` |
| Awaiting approval or response | `0xFF6D00` |
| Error | `0xFF0033` |
| Empty | off |

Ambient ring: recording is a snaking `0x2E8B57`, transcribing and inserting are
a snaking white, and a just-finished dictation is solid white. Otherwise the
ring snakes in the selected slot's color while that session is working, and is
off. The key lights stay off. After 10 minutes with no session update, key press
or dictation, everything goes dark and the next event restores the picture.

### Keys

A key arrives as a `v.oai.hid` notification with `k` naming the key and `act`
saying what happened: `act` 1 is a press and `act` 0 is a release, as observed
on the Micro. Only a press acts. The joystick (`v.oai.rad`) is not mapped.

| Key | Meaning | What Whisper does |
| --- | --- | --- |
| `AG00` to `AG05` | Slot 1 to 6 | Opens that Claude desktop session, or activates T3 Code for a T3 slot, and marks an unread slot idle. An empty slot does nothing. |
| `ACT09` | New task | Opens `claude://code/new`. |
| `ACT12` | Sessions waiting for you | Opens `claude://code/needs-input` with no session. |
| `ACT07` | Approve | Sends Return to Claude. |
| `ACT08` | Reject | Sends Escape to Claude. |
| `ACT06` | Stop | Sends Escape to Claude. |
| `ACT11` | Microphone | Not mapped here. It also sends F18, which push-to-talk handles. |

### Choosing what the Micro controls

The menu-bar menu has a **Claude / T3 Code / Codex** picker under **Codex Micro
lighting**. The choice is kept in the `codexMicroSurface` user default.

- **Claude**: the slots show only Claude desktop sessions, and the keys work as
  in the table above.
- **T3 Code**: the slots show only sessions run in T3 Code. Lighting is the same.
  The keys act on T3 instead:

  | Key | What Whisper does in T3 Code |
  | --- | --- |
  | Slot 1 to 6 | Opens `t3code://threads/<environmentID>/<threadID>`. If either ID is missing, brings T3 Code to the front. |
  | New task | Opens `t3code://new`. |
  | Sessions waiting for you | Opens the most recently updated T3 session that is awaiting approval or a response. Does nothing if none is. |
  | Approve, reject, stop | T3 Code has no keyboard shortcut for these, so the key opens the most recent T3 session in the matching state and sends no key. |

- **Codex**: Whisper stops sending lights and ignores the Micro's keys, so
  Codex.app can drive the Micro. Dictation lighting stops too.

For a Claude desktop slot, a slot key opens `claude://code/needs-input?session=<id>` when the slot is
awaiting approval or a response, and `claude://code/continue?session=<id>`
otherwise.

Claude's links accept only Claude's own `local_...` session ID, not the hook's
`session_id`. Whisper reads (never writes) the files Claude keeps for each Code
session at
`~/Library/Application Support/Claude/claude-code-sessions/<account>/<organization>/local_*.json`,
matches `cliSessionId` to the hook `session_id`, caches the match and rescans
when a session is not found. When there is still no match, an awaiting slot opens
`claude://code/needs-input` with no session and any other slot opens
`claude://code/continue?session=last`. Files with missing fields, an ID outside
the `local_` format or unreadable JSON are skipped. The folder is watched with
FSEvents, because Claude rewrites those files in place.

Approve, reject and stop send their key to Claude only (bundle ID
`com.anthropic.claudefordesktop`, posted to its process) and only when all of
these hold:

- Claude is the frontmost app.
- The focused session (the highest `lastFocusedAt`) is on the board.
- Its hook state is `awaiting-approval` for approve and reject, or `working` for
  stop.

Return is never sent in any other case, because Return in the composer sends a
message. When Claude is not frontmost, or the focused session is not in that
state, but some slot is awaiting approval (approve, reject) or working (stop),
the key opens the most recently updated such slot's link and sends no key; press
again once it is showing. Otherwise the press does nothing. Posting a key needs
Accessibility access for Whisper Dictation.

### Connection and diagnostics

One HID connection stays open to send lighting and to receive notifications. It
reconnects with a backoff of 1 to 30 seconds. All of its state lives on one
dedicated queue, and lighting writes are coalesced so the latest picture wins.
The last 50 notifications and plain keyboard events from the Micro, with
joystick events throttled to four a second, are kept in the
`codexMicroInputDiagnostic` user default. Every key action Whisper takes is
logged in the same list as an `action ...` line naming the key and the URL
opened, the key sent, or `ignored: <reason>`:

```bash
defaults read io.github.sp-hk2ldn.WhisperDictation codexMicroInputDiagnostic
```

## Build and install

The local build uses the Xcode selected by `xcode-select` (or `DEVELOPER_DIR`,
if set) and XcodeBuildMCP. To sign with your own team and bundle identifier,
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and edit it:

```sh
./scripts/install-local.sh
```

This builds the Release configuration, installs the signed app at:

```text
/Applications/Whisper Dictation.app
```

and launches it. The app is an `LSUIElement` menu-bar utility, so it has no
Dock icon or normal application window. Look for the microphone icon in the
menu bar.

This is a local Apple Development-signed build. Public distribution would
add Developer ID signing, hardened runtime, notarization, and a distributable
archive; those are intentionally outside this MVP.

## One-time setup

Open the microphone menu-bar item and choose **Settings…**:

1. Choose **Download Local Model**. The pinned model is
   `large-v3-v20240930_626MB`; expect approximately 600 MB of local storage.
2. Choose **Request Microphone Access** and allow the installed
   `Whisper Dictation` app.
3. Choose **Enable Accessibility**, then enable the same installed app under
   **System Settings → Privacy & Security → Accessibility**.

To change the shortcut, click the current chord beside **Push-to-talk
shortcut**, then press the replacement chord. Press Escape to cancel. Ordinary
keys require at least two modifiers to avoid stealing common macOS and terminal
shortcuts; F13–F20 may be used without modifiers. If Carbon reports a conflict,
the previous working shortcut is restored.

The hotkey never opens a permission dialog or begins a model download. Those
actions happen only from their explicit Settings buttons. macOS controls the
one-time privacy grants; automated tests cannot bypass TCC.

Keep the bundle at the stable `/Applications` path. All cross-application
smoke runners use that same signed identity, so Accessibility does not need
to be re-granted for temporary DerivedData builds.

## Use

1. Focus an editable text field.
2. Hold the configured shortcut.
3. Speak.
4. Release the shortcut.
5. Hold it again to record the next phrase while the previous phrase finishes.

Microphone capture can overlap transcription and insertion. The audio engine stays
warm while the queue is active, discards audio between shortcut holds, and stops
when the queue drains. The first recording from idle still starts the engine. Final transcripts
are processed and inserted in recording order, with one model inference and one
clipboard transaction at a time. Up to four sessions can be in flight; additional
presses show a wait message. The floating indicator prioritizes the live recording
and shows how many earlier phrases are processing. Each phrase retains its own
original target and is revalidated before insertion. Refused transcripts remain
available together for recovery.

The app captures the originating process and focused Accessibility element at
key-down. After transcription, it requires the same process and element to
still be focused. If no text field was focused at key-down, it looks for one
unambiguous, enabled, non-secure input in that window. It rechecks that window
and candidate before focusing the field and inserting. Multiple candidates,
changed focus, or failed validation fall back to recovery.

Failed insertion automatically copies only the latest failed phrase to the clipboard.
Recovery text remains available in the menu until explicitly copied/dismissed,
even when another recording starts. Multiple failed phrases are kept together.
Earlier failed phrases remain in the menu; automatic copying does not prepend them.
The floating indicator confirms successful clipboard copying.

Default insertion first uses direct Accessibility insertion. For controls that
do not support it, the app briefly saves the complete clipboard, pastes the
transcript, and restores the original clipboard. If another process changes
the clipboard during that transaction, the app does not overwrite the newer
contents. Automatic recovery and choosing **Copy Text** replace the current clipboard
contents with the retained transcript.

In Ghostty and Terminal, dictated line breaks and other submit-capable control
characters are converted to spaces. No insertion code synthesizes Return or
keypad Enter.

## How safe insertion works

Insertion is intentionally not a blind global paste:

1. On key-down, the app records the originating process, window, Accessibility
   element, role, position, and size.
2. After transcription, it checks that the same process and exact editable
   element still have focus.
3. It prefers direct `AXSelectedText` insertion when the destination supports
   it.
4. Compatibility exceptions use a typed destination registry. Their fallback
   snapshots every clipboard item and type, temporarily places the transcript
   on the pasteboard, posts Command-V directly to the captured process, and
   restores the snapshot only if nobody else changed the clipboard.
5. If focus changed or insertion cannot be made safely, nothing is typed. The
   transcript is offered for explicit recovery instead.

The terminal policy removes carriage return, line feed, tab, and other control
bytes before insertion. **No code path posts Return or keypad Enter.** A
transcription can populate a shell prompt, but it cannot execute it.

## Architecture

```text
MenuBarExtra / Settings
        │
DictationRuntime ── CarbonHotkeySource
        │
DictationSessionCoordinator
   ├── AVAudioEngineCapture → AudioPCMNormalizer (16 kHz mono Float32)
   ├── WhisperKitTranscriber (one final local decode)
   └── MacTextInsertionService
         ├── AX target capture and revalidation
         ├── AX selected-text insertion
         └── focus-revalidated, clipboard-restoring paste fallback
```

The coordinator owns session state and exactly-once insertion. Hotkey, audio,
transcription, target tracking, and insertion are protocol boundaries so an
adapter can be replaced without rewriting the lifecycle.

### Threading and lifecycle

- Main actor: menu-bar state, Settings, permission state, and pasteboard access
- Audio render callback: copies microphone buffers without blocking on ML or UI
- Coordinator tasks: session transitions, cancellation, and exactly-once rules
- WhisperKit actor: model loading and final inference away from the UI lifecycle
- Insertion actor: focus revalidation and destination-specific insertion

When idle, the app has no audio tap, helper process, local server, or expected
network socket.

## Focused verification

Run the unattended core suite:

```sh
./scripts/smoke.sh
```

It verifies:

- coordinator exactly-once, cancellation, focus-change, and terminal safety
- 48 kHz stereo to Whisper 16 kHz mono conversion
- real Carbon hotkey registration
- signed menu-bar process launch with no idle network socket
- known-speech Whisper transcription and warm/cold latency bounds
- cached transcription with network access denied

After the one-time Accessibility grant, run the real insertion adapters:

```sh
WHISPER_GUI_SMOKE=1 ./scripts/smoke-insertion-harness.sh
WHISPER_GUI_SMOKE=1 ./scripts/smoke-standard-apps.sh
WHISPER_GUI_SMOKE=1 ./scripts/smoke-notes.sh
WHISPER_GUI_SMOKE=1 ./scripts/smoke-ghostty.sh
WHISPER_GUI_SMOKE=1 ./scripts/smoke-terminal.sh
```

These GUI smokes deliberately activate their target apps and text fields. They
refuse to run under the normal user account: use a dedicated macOS login named
`whisper-smoke`, with its own disposable app data and one-time Microphone and
Accessibility grants, a prepared local model, and Automation permission for
the test runner to create and remove its disposable Notes fixture. Enable the
Notes **On My Mac** account so the fixture cannot sync. The explicit
`WHISPER_GUI_SMOKE=1` opt-in is also required. This prevents an unattended
agent from taking over the user's active cursor or keyboard focus.

These scripts never rebuild or replace the installed application. If source
changes, run `scripts/install-local.sh` first, grant the newly installed binary
once, and then keep that exact bundle in place while running the cross-app
smokes.

The terminal probes read PTY bytes and fail if Return or line feed is emitted.
They launch isolated terminal instances and stop only those instances.
The standard-app runner uses a disposable TextEdit document and isolated local
HTML fields in Chrome and Safari; it asserts the value through Accessibility
and does not use existing browser profiles or tabs.
The Notes runner creates a temporary note in the disposable test account,
verifies that the transcript appears exactly once, and deletes that note during
cleanup.

## Current MVP limits

- final transcription only; no editable streaming partials
- push-to-talk only; toggle mode is a replaceable later addition
- one recommended model; no model picker yet
- model remains loaded until the process quits
- local development signing only; not notarized for distribution

## Privacy and permissions

- **Microphone** is required only to capture speech while recording.
- **Accessibility** is required to identify the originating text element and
  insert text without stealing focus.
- **Automation** is not required by the app. It is used only by opt-in GUI smoke
  scripts in the disposable test account.
- Raw audio and transcript text are not logged by default.
- There is no analytics SDK, telemetry endpoint, account system, or cloud API.

The complete invariant list is in
[`docs/MVP_CONTRACT.md`](docs/MVP_CONTRACT.md).

## Project status

This repository contains a working local MVP aimed at Apple Silicon and macOS
14 or newer. It is development-signed for personal installation, not packaged
as a notarized public release. Model selection, toggle-to-talk, editable
streaming partials, and distribution packaging remain intentionally outside the
current slice.

WhisperKit and the Whisper model have their own upstream licenses. This
repository's own code is released under the MIT License (see `LICENSE`).
