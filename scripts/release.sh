#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"
fail() { print -u2 -- "Error: $*"; exit 1; }
step() { print -- "==> $*"; }

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  '') ;;
  *) fail "Usage: scripts/release.sh [--dry-run]" ;;
esac
(( $# <= 1 )) || fail "Usage: scripts/release.sh [--dry-run]"
version=$(awk '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ { print $3 }' Config/Shared.xcconfig)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Expected a numeric MARKETING_VERSION in Config/Shared.xcconfig"
tag="v$version"
release_dir="$repo_root/build/release"
zip_path="$release_dir/Whisper-Dictation-$version.zip"
app_path="$release_dir/Whisper Dictation.app"
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
derived_data=${WHISPER_DERIVED_DATA_PATH:-/private/tmp/whisperdictation-release}

if ! $dry_run; then
  [[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail "Git tree is dirty; commit or set aside changes before releasing."
  if git show-ref --verify --quiet "refs/tags/$tag"; then
    fail "Tag $tag already exists."
  fi
  [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || fail "Set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID for notarytool."
  [[ -r "$NOTARY_KEY_PATH" ]] || fail "NOTARY_KEY_PATH must point to a readable API key."
  command -v gh >/dev/null || fail "Install and authenticate the GitHub CLI (gh)."
  if [[ -n "${HOMEBREW_TAP_PATH:-}" ]]; then
    [[ -d "$HOMEBREW_TAP_PATH" ]] || fail "HOMEBREW_TAP_PATH must be a local tap clone."
    HOMEBREW_TAP_PATH=${HOMEBREW_TAP_PATH:A}
    [[ "$(git -C "$HOMEBREW_TAP_PATH" rev-parse --show-toplevel)" == "$HOMEBREW_TAP_PATH" ]] || fail "HOMEBREW_TAP_PATH must be the tap repository root."
    [[ -z "$(git -C "$HOMEBREW_TAP_PATH" status --porcelain --untracked-files=all)" ]] || fail "Tap tree is dirty."
  fi
fi

mkdir -p "$release_dir"
# Refuse stale bundles rather than merging their contents with a new build.
[[ ! -e "$app_path" ]] || fail "Move the previous build/release/Whisper Dictation.app aside before rerunning."
build_args=(
  -workspace "$repo_root/WhisperDictation.xcworkspace"
  -scheme WhisperDictation -configuration Release -destination 'generic/platform=macOS'
  -derivedDataPath "$derived_data" ARCHS=arm64
)
if $dry_run; then
  step "Build Release without signing (offline; cached Swift packages required)"
  xcodebuild "${build_args[@]}" -disableAutomaticPackageResolution -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
  ditto "$derived_data/Build/Products/Release/WhisperDictation.app" "$app_path"
else
  archive_path="$release_dir/WhisperDictation.xcarchive"
  [[ ! -e "$archive_path" && ! -e "$release_dir/export" ]] || fail "Move the previous archive/export aside before rerunning."
  step "Archive Release"
  xcodebuild "${build_args[@]}" -archivePath "$archive_path" archive
  cat > "$release_dir/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
</dict></plist>
PLIST
  step "Export Developer ID app (signing configured in Config/Local.xcconfig)"
  xcodebuild -exportArchive -archivePath "$archive_path" \
    -exportPath "$release_dir/export" -exportOptionsPlist "$release_dir/ExportOptions.plist"
  ditto "$release_dir/export/WhisperDictation.app" "$app_path"
  step "Verify Developer ID signature"
  codesign --verify --deep --strict "$app_path"
  signature=$(codesign -d --verbose=4 "$app_path" 2>&1)
  print -r -- "$signature" | /usr/bin/grep -q '^Authority=Developer ID Application' || fail "App is not signed with Developer ID Application."
fi

step "Zip $zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"
if ! $dry_run; then
  step "Notarise (wait for acceptance)"
  xcrun notarytool submit "$zip_path" --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --output-format plist > "$release_dir/notary-result.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$release_dir/notary-result.plist")" == Accepted ]] || fail "Notarisation was not accepted; inspect build/release/notary-result.plist."
  step "Staple ticket and re-zip"
  xcrun stapler staple "$app_path"
  ditto -c -k --keepParent "$app_path" "$zip_path"
  step "Assess with Gatekeeper"
  spctl -a -vv -t exec "$app_path"
fi
sha256=$(shasum -a 256 "$zip_path" | awk '{print $1}')
step "SHA-256: $sha256"
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha256/g" \
  packaging/homebrew/whisper-dictation.rb.template > "$release_dir/whisper-dictation.rb"
step "Wrote $release_dir/whisper-dictation.rb"
if $dry_run; then
  step "Dry run complete; unsigned archive is for packaging checks only."
  exit 0
fi

step "Tag $tag"
git tag "$tag"
step "Push $tag"
git push origin "refs/tags/$tag"
step "Publish GitHub release $tag"
gh release create "$tag" "$zip_path" --verify-tag --repo sp-hk2ldn/whisper-dictation \
  --title "Whisper Dictation $version" \
  --notes "Whisper Dictation $version for Apple Silicon, macOS 14 or newer. Install with: brew install --cask sp-hk2ldn/tap/whisper-dictation"
if [[ -n "${HOMEBREW_TAP_PATH:-}" ]]; then
  step "Update Homebrew tap cask"
  mkdir -p "$HOMEBREW_TAP_PATH/Casks"
  cp "$release_dir/whisper-dictation.rb" "$HOMEBREW_TAP_PATH/Casks/whisper-dictation.rb"
  step "Commit whisper-dictation $version in tap"
  git -C "$HOMEBREW_TAP_PATH" add -- Casks/whisper-dictation.rb
  git -C "$HOMEBREW_TAP_PATH" commit -m "whisper-dictation $version" -- Casks/whisper-dictation.rb
  step "Push Homebrew tap"
  git -C "$HOMEBREW_TAP_PATH" push
else
  step "HOMEBREW_TAP_PATH unset; copy the generated cask into the tap manually."
fi
