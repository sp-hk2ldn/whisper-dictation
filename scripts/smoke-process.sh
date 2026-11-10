#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
derived_data=/private/tmp/whisperdictation-process-smoke
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
workspace="$repo_root/WhisperDictation.xcworkspace"
app_path="$derived_data/Build/Products/Debug/WhisperDictation.app"
app_executable="$app_path/Contents/MacOS/WhisperDictation"
installed_app="/Applications/Whisper Dictation.app"
installed_executable="$installed_app/Contents/MacOS/WhisperDictation"
installed_pid=$(
  pgrep -f "$installed_executable" | head -1 || true
)
process_id=

cleanup() {
  if [[ -n "$process_id" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos stop --process-id "$process_id" >/dev/null 2>&1 \
      || true
  fi
  if [[ -n "$installed_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos launch --app-path "$installed_app" >/dev/null 2>&1 \
      || true
  fi
}
trap cleanup EXIT

if [[ -n "$installed_pid" ]]; then
  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos stop --process-id "$installed_pid"
fi

DEVELOPER_DIR="$developer_dir" \
xcodebuildmcp macos build \
  --workspace-path "$workspace" \
  --scheme WhisperDictation \
  --configuration Debug \
  --derived-data-path "$derived_data"

DEVELOPER_DIR="$developer_dir" \
  xcodebuildmcp macos launch \
  --app-path "$app_path" \
  --launch-args "--deterministic-smoke"

for _ in {1..40}; do
  process_id=$(pgrep -f "$app_executable" | head -1 || true)
  [[ -n "$process_id" ]] && break
  sleep 0.1
done

if [[ -z "$process_id" ]]; then
  print -u2 "Smoke failed: the built executable did not launch."
  exit 1
fi

kill -0 "$process_id"

if [[ $(plutil -extract LSUIElement raw "$app_path/Contents/Info.plist") != true ]]; then
  print -u2 "Smoke failed: the app is not configured as a menu-bar agent."
  exit 1
fi

if lsof -nP -a -p "$process_id" -i 2>/dev/null | sed -n '2p' | grep -q .; then
  print -u2 "Smoke failed: the idle app opened a network socket."
  exit 1
fi

print "Process smoke passed for PID $process_id with no idle network socket."
