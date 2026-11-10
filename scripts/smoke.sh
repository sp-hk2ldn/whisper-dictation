#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}

DEVELOPER_DIR="$developer_dir" \
xcodebuildmcp swift-package test \
  --package-path "$repo_root/WhisperDictationPackage" \
  --parallel false

DEVELOPER_DIR="$developer_dir" \
HOTKEY_SYSTEM_SMOKE=1 \
xcodebuildmcp swift-package test \
  --package-path "$repo_root/WhisperDictationPackage" \
  --filter HotkeySmokeTests \
  --parallel false

"$repo_root/scripts/smoke-process.sh"
"$repo_root/scripts/smoke-model.sh"

sandbox-exec \
  -p '(version 1) (allow default) (deny network*)' \
  env WHISPER_NETWORK_DENIED=1 \
  "$repo_root/scripts/smoke-model.sh"

print "All unattended MVP smoke gates passed."
