#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
derived_data=/private/tmp/whisperdictation-release
built_app="$derived_data/Build/Products/Release/WhisperDictation.app"
installed_app="/Applications/Whisper Dictation.app"

DEVELOPER_DIR="$developer_dir" \
xcodebuildmcp macos build \
  --workspace-path "$repo_root/WhisperDictation.xcworkspace" \
  --scheme WhisperDictation \
  --configuration Release \
  --derived-data-path "$derived_data"

installed_pid=$(
  pgrep -f \
    "^/Applications/Whisper Dictation\\.app/Contents/MacOS/WhisperDictation$" \
    | head -1 \
    || true
)
if [[ -n "$installed_pid" ]]; then
  DEVELOPER_DIR="$developer_dir" \
    xcodebuildmcp macos stop --process-id "$installed_pid"
fi

ditto "$built_app" "$installed_app"
codesign --verify --deep --strict --verbose=2 "$installed_app"

DEVELOPER_DIR="$developer_dir" \
xcodebuildmcp macos launch --app-path "$installed_app"

print "Installed and launched: $installed_app"
