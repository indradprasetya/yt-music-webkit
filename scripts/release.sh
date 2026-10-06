#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
profile="${1:-music-notary}"
team="${MUSIC_TEAM_ID:-B48JYPPTK6}"
identity="Developer ID Application"
repo="https://github.com/indradprasetya/yt-music-webkit"
mkdir -p dist
work=$(mktemp -d "$PWD/dist/release.XXXXXX")
release="$work/upload"
mkdir "$release"
printf 'Release workspace: %s\n' "$work"

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
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
        OTHER_CODE_SIGN_FLAGS=--timestamp archive > "$work/build-$arch.log" 2>&1
    xcodebuild -quiet -exportArchive -archivePath "$work/$arch.xcarchive" \
        -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export-$arch" \
        > "$work/export-$arch.log" 2>&1
    stage="$work/stage-$arch"
    mkdir "$stage"
    ditto "$work/export-$arch/Music.app" "$stage/Music.app"
    codesign --verify --deep --strict "$stage/Music.app"
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/Music.app/Contents/Info.plist")
    ln -s /Applications "$stage/Applications"
    if [ "$arch" = arm64 ]; then label=Apple-Silicon; else label=Intel; fi
    dmg="$release/Music-$version-$label.dmg"
    hdiutil create -quiet -volname Music -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
    codesign --sign "$identity" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --output-format json > "$work/submission-$arch.json"
    printf 'Submitted %s for notarization\n' "$label"
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
        --download-url-prefix "$repo/releases/download/v$version/" \
        --link "$repo/releases/tag/v$version" \
        -o "$release/appcast-$arch.xml" "$work/feed-$arch"
done
(cd "$release" && shasum -a 256 ./*.dmg ./appcast-*.xml > SHA256SUMS.txt)
printf '\nVerified release files ready to upload: %s\n' "$release"
