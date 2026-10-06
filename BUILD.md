# Build

Build Music on macOS using Swift and the system AppKit and WebKit frameworks. No third-party dependencies are required.

## Requirements

Install Xcode 16 or newer in `/Applications/Xcode.app` and open it once to finish setup. Use its toolchain for terminal commands:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Clone the repository and run the remaining commands from its root directory:

```sh
git clone https://github.com/indradprasetya/yt-music-webkit.git
cd yt-music-webkit
xcodebuild -version
```

If you already have a checkout, use that directory instead of cloning again.

## Build and run in Xcode

Open `Music.xcodeproj`, select the **Music** scheme and **My Mac**, then press **Command-R**. Open the project file rather than the repository folder. Source code, `Info.plist`, and the icon live in `Music/`.

The project uses AppKit and WebKit, supports macOS 12 or newer, and signs locally without an Apple Developer team. App version, build number, and bundle identifier are configured on the Music target in Xcode.

To build a development app from Terminal:

```sh
xcodebuild -project Music.xcodeproj -scheme Music \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath dist/DerivedData build
open dist/DerivedData/Build/Products/Debug/Music.app
```

## Build release apps and DMGs

Run this entire block from the repository root, in the same terminal session. It builds separate Apple Silicon and Intel apps through the Xcode project and packages each with an Applications shortcut for drag-and-drop installation.

```sh
bash <<'BUILD'
set -euo pipefail

mkdir -p dist
build_dir=$(mktemp -d "$PWD/dist/build.XXXXXX")

for arch in arm64 x86_64; do
    if [ "$arch" = arm64 ]; then
        label=Apple-Silicon
    else
        label=Intel
    fi

    xcodebuild -project Music.xcodeproj -scheme Music \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$build_dir/$arch" \
        ARCHS="$arch" ONLY_ACTIVE_ARCH=NO build

    stage="$build_dir/stage-$arch"
    app="$stage/Music.app"
    mkdir -p "$stage"
    ditto "$build_dir/$arch/Build/Products/Release/Music.app" "$app"
    codesign --verify --strict --verbose=2 "$app"
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    ln -s /Applications "$stage/Applications"

    dmg="dist/Music-${version}-${label}.dmg"
    hdiutil create -volname Music -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
    hdiutil verify "$dmg"
done
BUILD
```

The output filenames use the version from the built app:

- `dist/Music-<version>-Apple-Silicon.dmg`
- `dist/Music-<version>-Intel.dmg`

Intermediate builds and staged app bundles remain under `dist/build.<random>/`. The entire `dist/` directory is already ignored by Git. Existing DMGs are not overwritten: move or delete the previous output files before rebuilding the same version.

The apps use ad-hoc signing for local builds, without Developer ID signing or Apple notarization.

## Run

Open the DMG matching your Mac, drag `Music.app` into Applications, and launch it. Check playback and macOS Now Playing controls. Closing the window keeps playback running; click the Dock icon to reopen it, or press Command-Q to quit.
