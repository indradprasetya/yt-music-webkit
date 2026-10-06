# Build

Music uses Swift, AppKit, WebKit, and Sparkle 2.10.0. Install Xcode 16 or newer in `/Applications/Xcode.app` and open it once to finish setup.

## Development and checks

Open `Music.xcodeproj`, select the Music scheme and My Mac, then run. Debug builds use ad-hoc signing; Xcode downloads the pinned Sparkle package automatically.

From the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Music.xcodeproj -scheme Music \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath dist/updater-build build
python3 tests/check-updates.py
open dist/updater-build/Build/Products/Debug/Music.app
```

The check uses a temporary app and local HTTP server to exercise Sparkle: current build, newer build with the same display version, invalid feed, offline server, and persisted automatic-check settings. It verifies that disabling automatic checks makes no network requests.

Check the ⓘ title-bar menu visually, playback and Now Playing controls, and reopening the window after closing it. The app continues running until Command-Q.

## Signed, notarized releases

The release Mac needs a Developer ID Application certificate, a saved `notarytool` Keychain profile, and the existing Sparkle signing key. This project's profile is `music-notary`; the Sparkle key uses account `com.dyan.ytmusicwebkit`. Its public key is committed in `Music/Info.plist`; the private key remains in Keychain. When moving to another Mac, securely transfer the existing signing key instead of generating a replacement.

Keep `MARKETING_VERSION` as the user-facing version. Increase `CURRENT_PROJECT_VERSION` for every new distributed build, including rebuilds that keep the same displayed version. Music 1.1.0 with the corrected release packaging is build 6. Sparkle compares build numbers.

```sh
bash scripts/release.sh music-notary music-1.1.0
```

The script archives and exports separate Apple Silicon and Intel apps with hardened runtime and Developer ID signing, including Sparkle's helper executables. It restores the original 640 × 360 Finder installer window, background, and left-to-right Music → Applications icon layout, then creates and signs the DMGs, submits both to Apple, waits for acceptance, staples their tickets, and verifies the signatures and Gatekeeper assessment. Finally, it signs the finished DMGs for Sparkle and generates architecture-specific feeds and SHA-256 checksums.

It prints a new `dist/release.<random>/upload/` directory containing:

- `Music-1.1.0-Apple-Silicon.dmg`
- `Music-1.1.0-Intel.dmg`
- `appcast-arm64.xml`
- `appcast-x86_64.xml`
- `SHA256SUMS.txt`

The DMG filenames follow `MARKETING_VERSION`. Each run gets a separate directory so previous notarized packages are preserved. Logs, submissions, and staged apps remain in the parent release directory. `dist/` is ignored by Git. The script defaults to developer team `B48JYPPTK6`; `MUSIC_TEAM_ID` can select another team for a separate distribution.

## Publish to GitHub Releases

Push the source commit, then edit the existing stable GitHub Release with tag `music-1.1.0`. Replace its two old DMGs with the new packages, and add both XML feeds and the checksum file. For a new version, create a release whose tag matches the second argument supplied to the release script. Upload **all five files** from the new `upload/` directory and mark the release as latest. A source push alone does not publish the update packages or feeds. Use only the five files from the new upload folder; old DMGs and feeds from earlier builds do not match these signatures.

Music reads `releases/latest/download/appcast-arm64.xml` or `appcast-x86_64.xml`. Each feed points to the matching signed DMG under `releases/download/music-1.1.0/`. Until the first release containing these feeds is published, update checks report that they could not complete.

The release script defaults to tag `music-<marketing-version>`; its second argument can specify a different tag. For later releases, increase the build number, run the script with the intended tag, and publish its five output files together. Do not modify a finished DMG after feed generation: its signature and checksum cover those exact bytes.

After uploading, verify the public files and links with:

```sh
python3 tests/check-release.py --published music-1.1.0
```

This check also runs against the local upload folder before the release script reports success. It catches missing feeds, mismatched tags, incorrect package sizes, and mismatched checksums. `PUBLISH.txt` beside the upload folder records the exact release URL and publication steps.

Update checks run at launch and on Sparkle's normal background schedule. The automatic-check preference persists, and manual checks remain available when it is disabled. Background checks only mark the title-bar icon; downloading, installation, and restarting require user interaction.
