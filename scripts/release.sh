#!/bin/bash
set -euo pipefail
# New version: release.sh [notary-profile] vX.Y.Z
# New build of the latest version: release.sh [notary-profile] vX.Y.Z --rebuild
if [ "$#" -gt 3 ]; then
    echo "Usage: release.sh [notary-profile|--version] [tag] [--rebuild]" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
profile="${1:-music-notary}"
team="${MUSIC_TEAM_ID:-B48JYPPTK6}"
identity="Developer ID Application"
repo="https://github.com/indradprasetya/yt-music-webkit"
metadata=$(python3 - "${2:-}" "${3:-}" <<'PY'
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import subprocess
import sys

def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()

if sys.argv[2] not in ("", "--rebuild"):
    sys.exit("Usage: release.sh [notary-profile|--version] [tag] [--rebuild]")
rebuild = sys.argv[2] == "--rebuild"
if git("status", "--porcelain"):
    sys.exit("Commit or stash pending changes before building a release.")
if git("rev-parse", "--is-shallow-repository") == "true":
    sys.exit("Fetch full history and tags first: git fetch --unshallow --tags")

pattern = r"(?:v|music-)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
tags = [tag for tag in git("tag", "--list").splitlines() if re.fullmatch(pattern, tag)]
head = git("rev-parse", "HEAD")
current = [tag for tag in tags if git("rev-parse", tag + "^{commit}") == head]
tag = sys.argv[1] or (current[0] if len(current) == 1 else "")
if rebuild:
    if tag not in tags or not sys.argv[1]:
        sys.exit("Rebuild requires an explicit existing release tag.")
    if subprocess.run(["git", "merge-base", "--is-ancestor", tag, head]).returncode:
        sys.exit("Rebuild tag must be an ancestor of HEAD.")
    if git("rev-parse", tag + "^{commit}") == head:
        sys.exit("Rebuild requires a newer commit than the release tag.")
elif tag not in current:
    sys.exit("Release requires a vX.Y.Z tag on HEAD (legacy X.Y.Z and music-X.Y.Z also work). Pass it as the second argument if needed.")
version = tag.removeprefix("music-").removeprefix("v")
build = int(git("rev-list", "--count", "HEAD"))
for previous in tags:
    if previous == tag:
        continue
    previous_version = previous.removeprefix("music-").removeprefix("v")
    if previous_version == version and previous in current:
        continue
    if tuple(map(int, previous_version.split("."))) >= tuple(map(int, version.split("."))):
        sys.exit(f"Release version must be newer than {previous}.")
    if int(git("rev-list", "--count", previous)) >= build:
        sys.exit(f"Build number must exceed {previous}. Commit the release changes on the current release history first.")
# Sparkle compares internal build numbers, including rebuilds of the same version.
for feed in Path("updates").glob("appcast-*.xml"):
    for value in ET.parse(feed).findall("./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version"):
        if int(value.text) >= build:
            sys.exit(f"Build number must exceed {value.text} in {feed}. Commit the release changes first.")
print(tag, version, build)
PY
)
read -r release_tag version build <<< "$metadata"
if [ "$profile" = --version ]; then
    printf '%s\n' "$metadata"
    exit 0
fi
source_commit=$(git rev-parse HEAD)
printf 'Building %s (build %s) from %s\n' "$release_tag" "$build" "$source_commit"
mkdir -p dist
work=$(mktemp -d "$PWD/dist/release.XXXXXX")
release="$work/upload"
feeds="$work/updates"
source="$work/source"
mkdir "$release" "$feeds" "$source"
# Compile one immutable commit even if the checkout changes while notarization runs.
git archive "$source_commit" | tar -x -C "$source"
printf '%s\n' "$source_commit" > "$work/source-commit.txt"
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
    xcodebuild -quiet -project "$source/Music.xcodeproj" -scheme Music -configuration Release \
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
    test "$(lipo -archs "$stage/Music.app/Contents/MacOS/Music")" = "$arch"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/Music.app/Contents/Info.plist")" = "$version"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stage/Music.app/Contents/Info.plist")" = "$build"
    ln -s /Applications "$stage/Applications"
    mkdir "$stage/.background"
    cp "$source/packaging/dmg-background.png" "$stage/.background/background.png"
    if [ "$arch" = arm64 ]; then label=Apple-Silicon; else label=Intel; fi
    dmg="$release/Music-$version-$label.dmg"
    hdiutil create -quiet -volname "Music $version $label" -srcfolder "$stage" -fs HFS+ -format UDRW "$work/layout-$arch.dmg"
    mounted="$work/mount-$arch"
    mkdir "$mounted"
    hdiutil attach "$work/layout-$arch.dmg" -nobrowse -mountpoint "$mounted" -quiet
    osascript "$source/scripts/layout-dmg.applescript" "$mounted"
    python3 "$source/tests/check-dmg-layout.py" "$mounted"
    hdiutil detach "$mounted" -quiet
    mounted=""
    hdiutil convert "$work/layout-$arch.dmg" -format UDZO -o "$dmg" -quiet
    mounted="$work/mount-$arch"
    hdiutil attach "$dmg" -nobrowse -mountpoint "$mounted" -quiet
    python3 "$source/tests/check-dmg-layout.py" "$mounted"
    hdiutil detach "$mounted" -quiet
    mounted=""
    codesign --sign "$identity" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --output-format json > "$work/submission-$arch.json"
    submission=$(plutil -extract id raw "$work/submission-$arch.json")
    printf 'Submitted %s for notarization: %s\n' "$label" "$submission"
    printf 'Check status: DEVELOPER_DIR=%q xcrun notarytool info %q --keychain-profile %q\n' "$DEVELOPER_DIR" "$submission" "$profile"
done

sparkle="$PWD/dist/updater-build/SourcePackages/artifacts/sparkle/Sparkle/bin"
for arch in arm64 x86_64; do
    if [ "$arch" = arm64 ]; then label=Apple-Silicon; else label=Intel; fi
    dmg="$release/Music-$version-$label.dmg"
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
        -o "$feeds/appcast-$arch.xml" "$work/feed-$arch"
    signature=$(python3 - "$feeds/appcast-$arch.xml" <<'PYXML'
import sys
import xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).find("./channel/item/enclosure").get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"))
PYXML
)
    "$sparkle/sign_update" --account com.dyan.ytmusicwebkit --verify "$dmg" "$signature"
done
mkdir -p updates
cp "$feeds"/appcast-*.xml updates/
{
    (cd "$release" && shasum -a 256 ./*.dmg)
    (cd updates && shasum -a 256 ./appcast-*.xml)
} > updates/SHA256SUMS.txt
python3 tests/check-release.py "$release" "$release_tag"
python3 - "$repo" "$release_tag" "$version" <<'PY'
from pathlib import Path
import re
import sys

repo, tag, version = sys.argv[1:]
path = Path("README.md")
readme = path.read_text()
for label in ("Apple-Silicon", "Intel"):
    pattern = re.escape(repo) + rf"/releases/download/[^)\s]+/Music-[^)\s]+-{label}\.dmg"
    url = f"{repo}/releases/download/{tag}/Music-{version}-{label}.dmg"
    readme, count = re.subn(pattern, lambda _: url, readme)
    if count != 1:
        sys.exit(f"Expected one direct {label} download link in README.md.")
path.write_text(readme)
PY
# Publish locally only after both signed installers pass verification.
output="$PWD/dist/$version"
if [ -e "$output" ]; then mv "$output" "$work/previous-release"; fi
mv "$release" "$output"
receipts="$PWD/dist/notarization/$version-$build"
mkdir -p "$receipts"
cp "$work"/submission-*.json "$work"/status-*.json "$work"/notary-log-*.json "$work/source-commit.txt" "$receipts/"
rm -rf "$work"
printf '\nVerified release files ready to upload: %s\n' "$output"
printf 'Replace/upload both DMGs at %s/releases/tag/%s, then commit and push updates/ and README.md.\n' "$repo" "$release_tag"
printf 'Verify after publishing: python3 tests/check-release.py --published %s\n' "$release_tag"
