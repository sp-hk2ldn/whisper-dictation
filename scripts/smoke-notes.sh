#!/bin/zsh
set -euo pipefail

if [[ "${WHISPER_GUI_SMOKE:-}" != "1" || "$(id -un)" != "whisper-smoke" ]]; then
  print -u2 \
    "GUI smoke requires WHISPER_GUI_SMOKE=1 in the dedicated whisper-smoke macOS login."
  exit 2
fi

developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
app_path="/Applications/Whisper Dictation.app"
app_executable="$app_path/Contents/MacOS/WhisperDictation"
smoke_root=$(mktemp -d /private/tmp/whisperdictation-notes.XXXXXX)
fixture_path="$smoke_root/speech.caf"
status_path="$smoke_root/status.txt"
existing_app_pid=$(pgrep -f "$app_executable" | sed -n '1p' || true)
note_id=
app_pid=

delete_smoke_note() {
  [[ -n "$note_id" ]] || return
  osascript - "$note_id" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run arguments
    set smokeNoteID to item 1 of arguments
    tell application "Notes"
        set matchingNotes to every note whose id is smokeNoteID
        if (count of matchingNotes) is greater than 0 then
            delete item 1 of matchingNotes
        end if
    end tell
end run
APPLESCRIPT
}

cleanup() {
  if [[ -n "$app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos stop --process-id "$app_pid" >/dev/null 2>&1 \
      || true
  fi
  delete_smoke_note
  if [[ -n "$existing_app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos launch --app-path "$app_path" >/dev/null 2>&1 \
      || true
  fi
}
trap cleanup EXIT

codesign --verify --deep --strict "$app_path"
say \
  -v Samantha \
  -o "$fixture_path" \
  --data-format=LEF32@16000 \
  "The quick brown fox jumps over the lazy dog."

note_id=$(
  osascript <<'APPLESCRIPT'
tell application "Notes"
    set targetAccount to default account
    set targetFolder to default folder of targetAccount
    set smokeNote to make new note at targetFolder with properties {body:"<div>START:</div>"}
    show smokeNote separately true
    activate
    return id of smokeNote
end tell
APPLESCRIPT
)

if [[ -z "$note_id" ]]; then
  print -u2 "Notes smoke could not create its disposable note."
  exit 1
fi

sleep 2

if [[ -n "$existing_app_pid" ]]; then
  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos stop --process-id "$existing_app_pid"
fi

open -gn "$app_path" \
  --args \
    "--deterministic-smoke" \
    "--smoke-audio=$fixture_path" \
    "--smoke-status=$status_path" \
    "--smoke-run-once"

for _ in {1..40}; do
  app_pid=$(pgrep -f "$app_executable" | sed -n '1p' || true)
  [[ -n "$app_pid" ]] && break
  sleep 0.1
done

if [[ -z "$app_pid" ]]; then
  print -u2 "Notes smoke failed to launch Whisper Dictation."
  exit 1
fi

for _ in {1..960}; do
  note_text=$(
    osascript - "$note_id" <<'APPLESCRIPT'
on run arguments
    set smokeNoteID to item 1 of arguments
    tell application "Notes"
        set matchingNotes to every note whose id is smokeNoteID
        if (count of matchingNotes) is 0 then return ""
        return plaintext of item 1 of matchingNotes
    end tell
end run
APPLESCRIPT
  )

  if [[ "$note_text" == *"quick brown fox"* \
    && "$note_text" == *"lazy dog"* ]]; then
    occurrence_count=$(
      print -r -- "$note_text" \
        | grep -o "quick brown fox" \
        | wc -l \
        | tr -d " "
    )
    if [[ "$occurrence_count" != "1" ]]; then
      print -u2 \
        "Notes safety failed: transcript appeared $occurrence_count times."
      exit 1
    fi
    print "Notes insertion smoke passed with exactly one transcript."
    exit 0
  fi
  sleep 0.25
done

if [[ -f "$status_path" ]]; then
  smoke_status=$(<"$status_path")
else
  smoke_status="status unavailable"
fi
print -u2 "Notes insertion smoke timed out. $smoke_status"
exit 1
