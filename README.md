# Music

[![Version](https://img.shields.io/github/v/release/indradprasetya/yt-music-webkit?style=for-the-badge&color=0088cc&label=version&sort=date)](https://github.com/indradprasetya/yt-music-webkit/releases)
[![Downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Findradprasetya%2Fyt-music-webkit%2Fdownload-badge%2Fdownloads.json&style=for-the-badge)](https://github.com/indradprasetya/yt-music-webkit/releases)

<!-- Download badge: counts only .dmg assets across published releases, including prereleases.
     The Download badge workflow refreshes it hourly and on release changes; workflow_dispatch refreshes it manually.
     Generated data lives on the download-badge branch so updates do not change the app's build number. -->

Music is an unofficial YouTube Music app for macOS, built with Swift and WebKit. It opens the YouTube Music website in its own window, where you can sign in and access your library and playlists. You can play, pause, and change tracks from macOS Now Playing.

Your music keeps playing when you close the window. Click the Music icon in the Dock to reopen it, or press Command-Q to quit the app. Available for Apple Silicon and Intel Macs.

The ⓘ button in the top-right title bar shows the installed version and update status. Music checks for updates when launched and periodically while running. You can check manually, turn automatic checks off, or download and install an update from this menu. Installation restarts Music after you confirm.

## Download

[See GitHub Releases](https://github.com/indradprasetya/yt-music-webkit/releases)

## Screenshots

### Music window

![YouTube Music playing in the native macOS Music window](docs/screenshots/music-window.png)

### macOS Now Playing

![macOS Now Playing controls with album artwork, playback controls, and track progress](docs/screenshots/now-playing.png)

## License

Copyright (c) 2026 indradprasetya.

Music's source code is licensed under the **GNU General Public License version 3 only** (`GPL-3.0-only`). You may use, modify, and redistribute it under the terms of [LICENSE](LICENSE). It is provided without warranty.

When distributing Music or a modified version, provide the corresponding source code under GPLv3. See [Build and release](#build-and-release) for instructions.

Third-party components retain their own licenses. [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) contains the notices for Sparkle and its bundled components. Both license files are included in the app's `Contents/Resources` directory.

Music is not affiliated with or endorsed by Google or YouTube. YouTube Music, its branding, and the content accessed through the service are not covered by this project's license and remain subject to their respective owners' rights and the [YouTube Terms of Service](https://www.youtube.com/static?template=terms).

## Build and release

Open `Music.xcodeproj` in Xcode for development. Direct Xcode builds use `0.0.0` (build `0`); release builds get their versions from Git, without editing the project file.

Use a full Git clone with all release tags (`git fetch origin --tags`). Commit the release changes, then create a tag and run the release script. For example:

```sh
git tag -a music-1.1.2 -m "Music 1.1.2"
bash scripts/release.sh --version
bash scripts/release.sh
```

The tag sets the app version. The number of commits reachable from the tagged commit sets the build number, shared by Apple Silicon and Intel. The script requires a clean working tree and rejects versions or build numbers that do not increase over other local release tags. Keep release history intact; rebuilding the same tag keeps the same build number.

Releases require Xcode, a Developer ID Application certificate, notarization credentials in the `music-notary` Keychain profile, and the Sparkle signing key for `com.dyan.ytmusicwebkit`. To select another profile or an explicit tag, use `bash scripts/release.sh <profile> <tag>`.

The script builds, signs, notarizes, and verifies both DMGs, then generates the appcasts and checksums. It prints the upload folder and publishing instructions. Push the tag when publishing the GitHub Release, upload all five files, and mark the release Latest so the updater and version badge follow it.
