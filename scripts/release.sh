#!/bin/bash
set -euo pipefail
# Build the current files; version labels do not require local Git tags.
if [ "$#" -gt 3 ]; then
    echo "Usage: release.sh [notary-profile|--version] [vX.Y.Z] [--rebuild]" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
profile="${1:-music-notary}"
team="${MUSIC_TEAM_ID:-B48JYPPTK6}"
identity="Developer ID Application"
repo="https://github.com/indradprasetya/yt-music-webkit"
metadata=$(python3 - "${2:-}" "${3:-}" <<'PYMETA'
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

if sys.argv[2] not in ("", "--rebuild"):
    sys.exit("Usage: release.sh [notary-profile|--version] [vX.Y.Z] [--rebuild]")
rebuild = sys.argv[2] == "--rebuild"
project = Path("Music.xcodeproj/project.pbxproj").read_text()
versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project))
if len(versions) != 1:
    sys.exit("Debug and Release must have the same marketing version.")
project_version = versions.pop()
pattern = r"(?:v|music-)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
tag = sys.argv[1] or "v" + project_version
if not re.fullmatch(pattern, tag):
    sys.exit("Expected a release version such as v1.1.3.")
version = tag.removeprefix("music-").removeprefix("v")
if version != project_version:
    sys.exit("Release version must match MARKETING_VERSION in the project.")
latest = (0, 0, 0)
builds = [0]
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for feed in Path("updates").glob("appcast-*.xml"):
    for item in ET.parse(feed).findall("./channel/item"):
        previous = item.findtext(namespace + "shortVersionString")
        if not previous or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", previous):
            sys.exit(f"Invalid release version in {feed}.")
        latest = max(latest, tuple(map(int, previous.split("."))))
        value = item.findtext(namespace + "version", "")
        if not value.isdecimal() or int(value) <= 0:
            sys.exit(f"Invalid build number in {feed}.")
        builds.append(int(value))
for receipt in Path("dist/notarization").glob("*"):
    match = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)", receipt.name)
    if match:
        builds.append(int(match[2]))
        latest = max(latest, tuple(map(int, match[1].split("."))))
current = tuple(map(int, version.split(".")))
if current < latest or (current == latest and not rebuild):
    sys.exit("Version must be newer than the latest release; use --rebuild for the same version.")
if rebuild and current != latest:
    sys.exit("Rebuild requires the latest release version.")
print(tag, version, max(builds) + 1)
PYMETA
)
read -r release_tag version build <<< "$metadata"
if [ "$profile" = --version ]; then
    printf '%s\n' "$metadata"
    exit 0
fi
# Reuse the pinned binary package without invoking source-control tools.
sparkle_root=$(python3 - <<'PYSPARKLE'
from pathlib import Path
import json
import os
import plistlib
import sys
pins = json.loads(Path("Music.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]
version = next(pin["state"]["version"] for pin in pins if pin["identity"] == "sparkle")
if os.environ.get("MUSIC_SPARKLE_DIR"):
    candidates = [Path(os.environ["MUSIC_SPARKLE_DIR"])]
else:
    candidates = [Path("dist/updater-build/SourcePackages/artifacts/sparkle/Sparkle")]
    candidates += sorted((Path.home() / "Library/Developer/Xcode/DerivedData").glob("*/SourcePackages/artifacts/sparkle/Sparkle"))
for candidate in candidates:
    info = candidate / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Resources/Info.plist"
    if info.is_file() and plistlib.loads(info.read_bytes())["CFBundleShortVersionString"] == version:
        if all((candidate / "bin" / name).is_file() for name in ("generate_appcast", "sign_update")):
            print(candidate.resolve())
            break
else:
    sys.exit("Pinned Sparkle binary package unavailable. Set MUSIC_SPARKLE_DIR to its extracted package directory.")
PYSPARKLE
)
printf 'Building %s (build %s) from the current source files\n' "$release_tag" "$build"
mkdir -p dist
work=$(mktemp -d "$PWD/dist/release.XXXXXX")
release="$work/upload"
feeds="$work/updates"
source="$work/source"
mkdir "$release" "$feeds" "$source"
printf 'Release workspace: %s\n' "$work"
python3 - "$source" "$work" "$sparkle_root" <<'PYSOURCE'
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import sys
import tarfile
source, work, sparkle = map(Path, sys.argv[1:])
# Only public project inputs belong in the reproducible source snapshot.
for name in ("Music", "Music.xcodeproj", "packaging", "scripts", "tests", "docs", "updates", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.txt"):
    path = Path(name)
    if path.is_dir():
        shutil.copytree(path, source / name, ignore=shutil.ignore_patterns("xcuserdata", "*.xcuserstate", ".DS_Store", "__pycache__", ".git"))
    else:
        shutil.copy2(path, source / name)
manifest = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(source)}\n"
                   for path in sorted(source.rglob("*")) if path.is_file())
(work / "source-files.sha256").write_text(manifest)
with tarfile.open(work / "source.tar.gz", "w:gz") as archive:
    archive.add(source, arcname="source")
# Use the same pinned XCFramework through a local package only in the build copy.
package = work / "Sparkle"
package.mkdir()
subprocess.run(["ditto", str(sparkle / "Sparkle.xcframework"), str(package / "Sparkle.xcframework")], check=True)
(package / "Package.swift").write_text('// swift-tools-version:5.5\nimport PackageDescription\nlet package = Package(name: "Sparkle", platforms: [.macOS(.v12)], products: [.library(name: "Sparkle", targets: ["Sparkle"])], targets: [.binaryTarget(name: "Sparkle", path: "Sparkle.xcframework")])\n')
project = source / "Music.xcodeproj/project.pbxproj"
text = project.read_text()
text, count = re.subn(r'isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "https://github.com/sparkle-project/Sparkle";\s*requirement = \{[^}]+\};',
                     'isa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ../Sparkle;', text)
if count != 1:
    sys.exit("Expected exactly one pinned Sparkle package reference.")
project.write_text(text.replace("XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference"))
(source / "Music.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").unlink()
PYSOURCE
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
        -clonedSourcePackagesDirPath "$work/SourcePackages" -skipPackageUpdates \
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

sparkle="$sparkle_root/bin"
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
if [ -e "$output" ]; then mv "$output" "$PWD/dist/previous-$version-before-build-$build"; fi
mv "$release" "$output"
receipts="$PWD/dist/notarization/$version-$build"
mkdir -p "$receipts"
cp "$work"/submission-*.json "$work"/status-*.json "$work"/notary-log-*.json "$work/source-files.sha256" "$work/source.tar.gz" "$receipts/"
rm -rf "$work"
printf '\nVerified release files ready to upload: %s\n' "$output"
printf 'Replace/upload both DMGs at %s/releases/tag/%s, then commit and push updates/ and README.md.\n' "$repo" "$release_tag"
printf 'Verify after publishing: python3 tests/check-release.py --published %s\n' "$release_tag"
