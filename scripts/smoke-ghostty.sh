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
fixture_path=/private/tmp/whisperdictation-ghostty-smoke.caf
result_path=/private/tmp/whisperdictation-terminal-probe.bin
status_path=/private/tmp/whisperdictation-ghostty-status.txt
ghostty_binary=/Applications/Ghostty.app/Contents/MacOS/ghostty
existing_app_pid=$(
  pgrep -f "$app_executable" | head -1 || true
)
clipboard_sentinel="whisper-ghostty-clipboard-sentinel"

rm -f "$fixture_path" "$result_path" "$status_path"
print -n "$clipboard_sentinel" | pbcopy

say \
  -v Samantha \
  -o "$fixture_path" \
  --data-format=LEF32@16000 \
  "The quick brown fox jumps over the lazy dog."

DEVELOPER_DIR="$developer_dir" \
xcodebuildmcp swift-package build \
  --package-path "$repo_root/WhisperDictationPackage" \
  --configuration debug

probe_binary="$repo_root/WhisperDictationPackage/.build/arm64-apple-macosx/debug/TerminalProbe"
before_pids=(${(f)"$(pgrep -f "$ghostty_binary" || true)"})

open -na /Applications/Ghostty.app \
  --args -e "$probe_binary" "--result=$result_path"

ghostty_pid=
app_pid=

cleanup() {
  if [[ -n "$app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos stop --process-id "$app_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ghostty_pid" ]]; then
    kill "$ghostty_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$existing_app_pid" ]]; then
    DEVELOPER_DIR="$developer_dir" \
      xcodebuildmcp macos launch --app-path "$app_path" >/dev/null 2>&1 \
      || true
  fi
}
trap cleanup EXIT

for _ in {1..50}; do
  after_pids=(${(f)"$(pgrep -f "$ghostty_binary" || true)"})
  for candidate in $after_pids; do
    if (( ! ${before_pids[(Ie)$candidate]} )); then
      ghostty_pid=$candidate
      break
    fi
  done
  [[ -n "$ghostty_pid" && -f "$result_path" ]] && break
  sleep 0.1
done

if [[ -z "$ghostty_pid" || ! -f "$result_path" ]]; then
  print -u2 "Ghostty terminal probe did not initialize."
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
  print -u2 "Ghostty smoke failed to launch the installed app."
  exit 1
fi

for _ in {1..960}; do
  if LC_ALL=C grep -q "quick brown fox" "$result_path" 2>/dev/null; then
    if od -An -t u1 "$result_path" | tr -s ' ' '\n' | grep -Eq '^(10|13)$'; then
      print -u2 "Terminal safety failed: Return or newline reached the PTY."
      exit 1
    fi
    if [[ "$(pbpaste)" != "$clipboard_sentinel" ]]; then
      print -u2 "Ghostty insertion changed the clipboard."
      exit 1
    fi
    print "Ghostty insertion smoke passed without command submission."
    exit 0
  fi
  sleep 0.25
done

if [[ -f "$status_path" ]]; then
  smoke_status=$(<"$status_path")
else
  smoke_status="status unavailable"
fi
print -u2 "Ghostty insertion smoke timed out. $smoke_status"
exit 1
