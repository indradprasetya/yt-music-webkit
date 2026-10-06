#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
profile="${1:-music-notary}"
team="${MUSIC_TEAM_ID:-B48JYPPTK6}"
identity="Developer ID Application"
repo="https://github.com/indradprasetya/yt-music-webkit"
metadata=$(python3 - "${2:-}" <<'PY'
import re
import subprocess
import sys

def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()

if git("status", "--porcelain"):
    sys.exit("Commit or stash pending changes before building a release.")
if git("rev-parse", "--is-shallow-repository") == "true":
    sys.exit("Fetch full history and tags first: git fetch --unshallow --tags")

pattern = r"(?:music-)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
tags = [tag for tag in git("tag", "--list").splitlines() if re.fullmatch(pattern, tag)]
head = git("rev-parse", "HEAD")
current = [tag for tag in tags if git("rev-parse", tag + "^{commit}") == head]
tag = sys.argv[1] or (current[0] if len(current) == 1 else "")
if tag not in current:
    sys.exit("Release requires an X.Y.Z tag on HEAD (legacy music-X.Y.Z also works). Pass it as the second argument if needed.")
version = tag.removeprefix("music-")
build = int(git("rev-list", "--count", "HEAD"))
for previous in tags:
    if previous == tag:
        continue
    if previous.removeprefix("music-") == version and previous in current:
        continue
    if tuple(map(int, previous.removeprefix("music-").split("."))) >= tuple(map(int, version.split("."))):
        sys.exit(f"Release version must be newer than {previous}.")
    if int(git("rev-list", "--count", previous)) >= build:
        sys.exit(f"Build number must exceed {previous}. Commit the release changes on the current release history first.")
print(tag, version, build)
PY
)
read -r release_tag version build <<< "$metadata"
if [ "$profile" = --version ]; then
    printf '%s\n' "$metadata"
    exit 0
fi
printf 'Building %s (build %s)\n' "$release_tag" "$build"
mkdir -p dist
work=$(mktemp -d "$PWD/dist/release.XXXXXX")
release="$work/upload"
mkdir "$release"
printf 'Release workspace: %s\n' "$work"
mounted=""
trap 'if [ -n "$mounted" ]; then hdiutil detach "$mounted" -quiet || true; fi' EXIT

cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$identity</string>
</dict></plist>
PLIST

for arch in arm64 x86_64; do
    xcodebuild -quiet -project Music.xcodeproj -scheme Music -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$work/build" \
        -clonedSourcePackagesDirPath "$PWD/dist/updater-build/SourcePackages" \
        -archivePath "$work/$arch.xcarchive" ARCHS="$arch" ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
        OTHER_CODE_SIGN_FLAGS=--timestamp archive > "$work/build-$arch.log" 2>&1
    xcodebuild -quiet -exportArchive -archivePath "$work/$arch.xcarchive" \
        -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export-$arch" \
        > "$work/export-$arch.log" 2>&1
    stage="$work/stage-$arch"
    mkdir "$stage"
    ditto "$work/export-$arch/Music.app" "$stage/Music.app"
    codesign --verify --deep --strict "$stage/Music.app"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/Music.app/Contents/Info.plist")" = "$version"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/Music.app/Contents/Info.plist")" = "$build"
    ln -s /Applications "$stage/Applications"
    mkdir "$stage/.background"
    cp packaging/dmg-background.png "$stage/.background/background.png"
    if [ "$arch" = arm64 ]; then label=Apple-Silicon; else label=Intel; fi
    dmg="$release/Download-Music-$label.dmg"
    hdiutil create -quiet -volname "Music $version $label" -srcfolder "$stage" -fs HFS+ -format UDRW "$work/layout-$arch.dmg"
    mounted="$work/mount-$arch"
    mkdir "$mounted"
    hdiutil attach "$work/layout-$arch.dmg" -nobrowse -mountpoint "$mounted" -quiet
    osascript scripts/layout-dmg.applescript "$mounted"
    test -s "$mounted/.DS_Store"
    hdiutil detach "$mounted" -quiet
    mounted=""
    hdiutil convert "$work/layout-$arch.dmg" -format UDZO -o "$dmg" -quiet
    codesign --sign "$identity" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --output-format json > "$work/submission-$arch.json"
    printf 'Submitted %s for notarization\n' "$label"
done

sparkle="$PWD/dist/updater-build/SourcePackages/artifacts/sparkle/Sparkle/bin"
for arch in arm64 x86_64; do
    if [ "$arch" = arm64 ]; then label=Apple-Silicon; else label=Intel; fi
    dmg="$release/Download-Music-$label.dmg"
    submission=$(plutil -extract id raw "$work/submission-$arch.json")
    xcrun notarytool wait "$submission" --keychain-profile "$profile" --timeout 1h --output-format json > "$work/status-$arch.json"
    xcrun notarytool log "$submission" --keychain-profile "$profile" "$work/notary-log-$arch.json"
    test "$(plutil -extract status raw "$work/status-$arch.json")" = Accepted
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    codesign --verify --strict "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    spctl --assess --type execute --verbose=2 "$work/stage-$arch/Music.app"
    mkdir "$work/feed-$arch"
    ln "$dmg" "$work/feed-$arch/$(basename "$dmg")"
    "$sparkle/generate_appcast" --account com.dyan.ytmusicwebkit --maximum-deltas 0 \
        --download-url-prefix "$repo/releases/download/$release_tag/" \
        --link "$repo/releases/tag/$release_tag" \
        -o "$release/appcast-$arch.xml" "$work/feed-$arch"
done
mkdir -p updates
cp "$release"/appcast-*.xml updates/
(cd "$release" && shasum -a 256 ./*.dmg ./appcast-*.xml) > updates/SHA256SUMS.txt
python3 tests/check-release.py "$release" "$release_tag"
cat > "$work/PUBLISH.txt" <<TEXT
GitHub release: $repo/releases/tag/$release_tag
Upload these four files from $release to a draft release:
  Download-Music-Apple-Silicon.dmg
  Download-Music-Intel.dmg
  appcast-arm64.xml
  appcast-x86_64.xml
Keep the DMG names unchanged: the download badges count these exact names.
Publish the release and mark it Latest, then immediately commit and push updates/ to main.
New apps read the repository feeds. Keep the two release XML files while supporting
apps older than 1.1.1, which still read releases/latest/download/appcast-<arch>.xml.
Checksums are in updates/SHA256SUMS.txt; do not upload them as a release asset.
After publishing: python3 tests/check-release.py --published $release_tag
TEXT
printf '\nVerified release files ready to upload: %s\n' "$release"
