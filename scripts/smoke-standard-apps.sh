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
smoke_root=$(mktemp -d /private/tmp/whisperdictation-standard-apps.XXXXXX)
fixture_path="$smoke_root/speech.caf"
text_path="$smoke_root/textedit-target.txt"
html_path="$smoke_root/browser-target.html"
chrome_profile="$smoke_root/chrome-profile"
existing_app_pid=$(pgrep -f "$app_executable" | head -1 || true)
whisper_pid=
target_pids=()

cleanup() {
  if [[ -n "$whisper_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos stop --process-id "$whisper_pid" >/dev/null 2>&1 \
      || true
  fi
  for target_pid in $target_pids; do
    kill "$target_pid" >/dev/null 2>&1 || true
  done
  pkill -f "$chrome_profile" >/dev/null 2>&1 || true
  if [[ -n "$existing_app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos launch --app-path "$app_path" >/dev/null 2>&1 \
      || true
  fi
}
trap cleanup EXIT

codesign --verify --deep --strict "$app_path"
print -n "START:" > "$text_path"
print \
  '<!doctype html><meta charset="utf-8"><title>Whisper Dictation Smoke</title><textarea id="target" autofocus style="width:600px;height:240px;font-size:18px">START:</textarea><script>target.focus();setInterval(()=>target.focus(),100)</script>' \
  > "$html_path"
say \
  -v Samantha \
  -o "$fixture_path" \
  --data-format=LEF32@16000 \
  "The quick brown fox jumps over the lazy dog."

if [[ -n "$existing_app_pid" ]]; then
  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos stop --process-id "$existing_app_pid"
fi

run_insertion() {
  local label=$1
  local status_path="$smoke_root/$label-status.txt"

  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos launch \
    --app-path "$app_path" \
    --launch-args \
      "--deterministic-smoke" \
      "--smoke-audio=$fixture_path" \
      "--smoke-status=$status_path" \
      "--smoke-run-once"

  for _ in {1..960}; do
    whisper_pid=$(pgrep -f "$app_executable" | head -1 || true)
    if [[ -f "$status_path" ]]; then
      smoke_status=$(<"$status_path")
      [[ "$smoke_status" == final* ]] && break
    fi
    sleep 0.25
  done

  if [[ "${smoke_status:-}" != *"accessibility=true"* \
    || "${smoke_status:-}" != *"phase=idle"* \
    || "${smoke_status:-}" != *"insertion=insert ax-confirmed"* ]]; then
    print -u2 "$label insertion failed: ${smoke_status:-status unavailable}"
    exit 1
  fi

  print "$label insertion passed: $smoke_status"
  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos stop --process-id "$whisper_pid" >/dev/null
  whisper_pid=
}

open -na /System/Applications/TextEdit.app "$text_path"
sleep 2
textedit_pid=$(
  pgrep -n -f \
    "^/System/Applications/TextEdit\\.app/Contents/MacOS/TextEdit"
)
target_pids+=("$textedit_pid")
run_insertion "TextEdit"
kill "$textedit_pid" >/dev/null 2>&1 || true
target_pids=(${target_pids:#$textedit_pid})

open -na "/Applications/Google Chrome.app" \
  --args \
    "--user-data-dir=$chrome_profile" \
    "--no-first-run" \
    "--no-default-browser-check" \
    "file://$html_path"
sleep 3
chrome_pid=$(
  ps -axo pid=,command= \
    | awk -v marker="$chrome_profile" \
      'index($0, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") && index($0, marker) { print $1; exit }'
)
target_pids+=("$chrome_pid")
run_insertion "Chrome"
kill "$chrome_pid" >/dev/null 2>&1 || true
pkill -f "$chrome_profile" >/dev/null 2>&1 || true
target_pids=(${target_pids:#$chrome_pid})

open -na "/Applications/Safari.app" "file://$html_path"
sleep 3
safari_pid=$(pgrep -n -f "/Safari\\.app/Contents/MacOS/Safari")
target_pids+=("$safari_pid")
run_insertion "Safari"
kill "$safari_pid" >/dev/null 2>&1 || true
target_pids=(${target_pids:#$safari_pid})

print "All standard-app insertion smokes passed."
