#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
fixture_path=/private/tmp/whisperdictation-model-smoke.caf
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}

say \
  -v Samantha \
  -o "$fixture_path" \
  --data-format=LEF32@16000 \
  "The quick brown fox jumps over the lazy dog."

if [[ ${WHISPER_NETWORK_DENIED:-0} == 1 ]]; then
  # The outer sandbox is the network boundary. Disable SwiftPM's nested
  # subprocess sandbox so its manifest compiler can run inside that boundary.
  DEVELOPER_DIR="$developer_dir" \
  WHISPER_EVAL_AUDIO="$fixture_path" \
  swift test \
    --disable-sandbox \
    --package-path "$repo_root/WhisperDictationPackage" \
    --filter WhisperModelEvalSmokeTests \
    --no-parallel
else
  DEVELOPER_DIR="$developer_dir" \
  WHISPER_EVAL_AUDIO="$fixture_path" \
  xcodebuildmcp swift-package test \
    --package-path "$repo_root/WhisperDictationPackage" \
    --filter WhisperModelEvalSmokeTests \
    --parallel false
fi
