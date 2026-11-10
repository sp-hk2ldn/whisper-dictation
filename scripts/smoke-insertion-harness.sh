#!/bin/zsh
set -euo pipefail

if [[ "${WHISPER_GUI_SMOKE:-}" != "1" || "$(id -un)" != "whisper-smoke" ]]; then
  print -u2 \
    "GUI smoke requires WHISPER_GUI_SMOKE=1 in the dedicated whisper-smoke macOS login."
  exit 2
fi

repo_root=${0:A:h:h}
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
app_path="/Applications/Whisper Dictation.app"
app_executable="$app_path/Contents/MacOS/WhisperDictation"
fixture_path=/private/tmp/whisperdictation-insertion-smoke.caf
result_path=/private/tmp/whisperdictation-insertion-result.txt
status_path=/private/tmp/whisperdictation-insertion-status.txt
existing_app_pid=$(
  pgrep -f "$app_executable" | head -1 || true
)

rm -f "$fixture_path" "$result_path" "$status_path"

say \
  -v Samantha \
  -o "$fixture_path" \
  --data-format=LEF32@16000 \
  "The quick brown fox jumps over the lazy dog."

DEVELOPER_DIR="$developer_dir" \
xcodebuildmcp swift-package build \
  --package-path "$repo_root/WhisperDictationPackage" \
  --configuration debug

harness_binary="$repo_root/WhisperDictationPackage/.build/arm64-apple-macosx/debug/InsertionHarness"
"$harness_binary" "--result=$result_path" "--recreate-target" &
harness_pid=$!
app_pid=

cleanup() {
  if [[ -n "$app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos stop --process-id "$app_pid" >/dev/null 2>&1 || true
  fi
  kill "$harness_pid" >/dev/null 2>&1 || true
  if [[ -n "$existing_app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos launch --app-path "$app_path" >/dev/null 2>&1 \
      || true
  fi
}
trap cleanup EXIT

for _ in {1..40}; do
  [[ -f "$result_path" ]] && break
  sleep 0.1
done

if [[ $(<"$result_path") != "START:" ]]; then
  print -u2 "Insertion harness did not initialize."
  exit 1
fi

codesign --verify --deep --strict "$app_path"

if [[ -n "$existing_app_pid" ]]; then
  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos stop --process-id "$existing_app_pid"
fi

DEVELOPER_DIR="$developer_dir" \
  xcodebuildmcp macos launch \
  --app-path "$app_path" \
  --launch-args \
    "--deterministic-smoke" \
    "--smoke-audio=$fixture_path" \
    "--smoke-status=$status_path" \
    "--smoke-run-once"

for _ in {1..40}; do
  app_pid=$(pgrep -f "$app_executable" | head -1 || true)
  [[ -n "$app_pid" ]] && break
  sleep 0.1
done

if [[ -z "$app_pid" ]]; then
  print -u2 "Insertion smoke failed to launch the app."
  exit 1
fi

for _ in {1..960}; do
  result=$(<"$result_path")
  if [[ "$result" == *"quick brown fox"* && "$result" == *"lazy dog"* ]]; then
    print "Insertion smoke passed: $result"
    exit 0
  fi
  sleep 0.25
done

if [[ -f "$status_path" ]]; then
  smoke_status=$(<"$status_path")
else
  smoke_status="status unavailable"
fi
print -u2 "Insertion smoke timed out. $smoke_status. Final target text: $(<"$result_path")"
exit 1
