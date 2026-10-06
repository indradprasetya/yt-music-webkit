# Build

Build Music on macOS using Swift and the system AppKit and WebKit frameworks. No third-party dependencies are required.

## Requirements

Install Xcode in `/Applications/Xcode.app` and open it once to finish setup. Use its toolchain for this terminal session:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The two-architecture build below needs a toolchain with both ARM and Intel Swift libraries. Some standalone Command Line Tools installations only include ARM compatibility libraries, causing the Intel link step to fail.

Clone the repository and run the remaining commands from its root directory:

```sh
git clone https://github.com/indradprasetya/yt-music-webkit.git
cd yt-music-webkit
xcrun swiftc --version
```

If you already have a checkout, use that directory instead of cloning again.

## Build the app and DMGs

Run this entire block from the repository root, in the same terminal session. It reads the version and minimum macOS version from `Info.plist`, builds separate Apple Silicon and Intel apps, signs them locally, and packages each with an Applications shortcut for drag-and-drop installation.

```sh
bash <<'BUILD'
set -euo pipefail

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
min_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
sdk=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p dist
build_dir=$(mktemp -d "$PWD/dist/build-${version}.XXXXXX")

for arch in arm64 x86_64; do
    if [ "$arch" = arm64 ]; then
        label=Apple-Silicon
    else
        label=Intel
    fi

    stage="$build_dir/$arch"
    app="$stage/Music.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp Info.plist "$app/Contents/Info.plist"
    cp icon.icns "$app/Contents/Resources/icon.icns"

    xcrun swiftc Music.swift -O \
        -target "${arch}-apple-macosx${min_macos}" \
        -sdk "$sdk" -framework AppKit -framework WebKit \
        -o "$app/Contents/MacOS/Music"

    codesign --force --sign - "$app"
    codesign --verify --strict --verbose=2 "$app"
    ln -s /Applications "$stage/Applications"

    dmg="dist/Music-${version}-${label}.dmg"
    hdiutil create -volname Music -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
    hdiutil verify "$dmg"
done
BUILD
```

The output filenames use the version from `Info.plist`:

- `dist/Music-<version>-Apple-Silicon.dmg`
- `dist/Music-<version>-Intel.dmg`

Intermediate app bundles remain under `dist/build-<version>.<random>/`. The entire `dist/` directory is already ignored by Git. Existing DMGs are not overwritten: move or delete the previous output files before rebuilding the same version.

The apps use ad-hoc signing for local builds, without Developer ID signing or Apple notarization.

## Run

Open the DMG matching your Mac, drag `Music.app` into Applications, and launch it. Check playback and macOS Now Playing controls. Closing the window keeps playback running; click the Dock icon to reopen it, or press Command-Q to quit.
