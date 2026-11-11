# Releasing Whisper Dictation

Releases run manually on an Apple Silicon Mac with Xcode selected by
`xcode-select -p` (or `DEVELOPER_DIR`). There is no CI release job.

## One-time setup

1. Install a **Developer ID Application** certificate and its private key in
   your signing keychain through your Apple Developer membership.
2. Copy `Config/Local.xcconfig.example` to the git-ignored
   `Config/Local.xcconfig`. Set your `DEVELOPMENT_TEAM` and your own bundle ID
   for local builds. The release script overrides the bundle ID with
   `io.github.sp-hk2ldn.WhisperDictation` for dry-run and full builds. Configure
   signing overrides here if needed. Release enables hardened runtime and
   microphone audio-input entitlement; the app remains unsandboxed.
3. Create an App Store Connect API key authorized for notarization. Keep the
   `.p8` key outside the repository. Export `NOTARY_KEY_PATH` (the key file),
   `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID` in your shell. Never commit these
   values, personal signing identities, or local paths.
4. Install and authenticate `gh` with release access to
   `sp-hk2ldn/whisper-dictation`, and configure Git push access.
5. Create `sp-hk2ldn/homebrew-tap` separately, clone it locally, and export
   `HOMEBREW_TAP_PATH` pointing to that clean clone. The release script commits
   `Casks/whisper-dictation.rb` on `release/whisper-dictation-<version>`, created
   from the fetched `origin/main`, pushes that branch, and opens a PR against
   main. If unset, it only generates the cask for manual transfer via a PR.

## Offline packaging check

```sh
zsh -n scripts/release.sh
scripts/release.sh --dry-run
```

The dry run builds Release for arm64 with signing disabled, copies
`WhisperDictation.app` as `Whisper Dictation.app`, creates
`build/release/Whisper-Dictation-<version>.zip`, prints SHA-256, and fills in
`build/release/whisper-dictation.rb`. It permits a dirty tree and existing tag.
It never exports, notarizes, tags, pushes, invokes GitHub, or updates the tap.
The unsigned ZIP is for packaging checks; do not distribute it as a release.

Swift package dependencies must already be cached: package updates and automatic
resolution are disabled in dry-run mode. The default DerivedData directory is
`/private/tmp/whisperdictation-release`, shared with `install-local.sh`; set
`WHISPER_DERIVED_DATA_PATH` to use another prepared cache. On a new Mac, first
build from source with network access to populate dependencies. No certificate
or notarization credentials are needed for dry-run mode.

## Publish a release

1. Set `MARKETING_VERSION` in `Config/Shared.xcconfig`, review the changes, and
   commit through the repository's normal review process. Ensure the working
   tree is clean and `v<version>` does not already exist locally or on origin.
2. Both modes remove the script-owned `build/release` directory at startup.
   Preserve any output you need before rerunning. Avoid concurrent release runs
   or another build against the same DerivedData directory.
3. Run `scripts/release.sh` without flags. This is the publishing command.

Full mode fetches `origin main` and refuses unless `HEAD` equals `origin/main`.
The script archives Release, exports using `developer-id`, verifies the public
bundle ID, strict signature and Developer ID authority, then creates the ZIP with `ditto`.
It submits the ZIP to `notarytool --wait`, requires an Accepted result, staples
the app, recreates the ZIP, and assesses the app with Gatekeeper. It then prints
the final SHA-256 and generates the cask from the stapled archive.

Only after those checks does it create and push `v<version>`, create the GitHub
release with the ZIP attached, and optionally commit the tap cask as
`whisper-dictation <version>` on its release branch, push that branch, and open
a PR against main. It prints the PR URL and does not merge it. Merge the tap PR
to finish the release. Every step is printed. Full mode needs network access;
it is never part of the dry run.

If publishing fails partway through, inspect local/remote tags, the GitHub
release and the tap before resuming manually. The script does not roll back
published state or bypass its existing-tag guard. Notarization results and
export options remain under the ignored `build/release/` for diagnosis.

After publication, verify the release asset and cask checksum, then install via:

```sh
brew install --cask sp-hk2ldn/tap/whisper-dictation
```

Launch the installed app and verify Microphone and Accessibility grants and a
real dictation. Packaging checks alone do not verify those runtime permissions.
