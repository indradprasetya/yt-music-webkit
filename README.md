# Music

[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fapi.github.com%2Frepos%2Findradprasetya%2Fyt-music-webkit%2Freleases%2Flatest&query=%24.tag_name&label=version&color=0088cc&style=for-the-badge)](https://github.com/indradprasetya/yt-music-webkit/releases)
[![Apple Silicon downloads](https://img.shields.io/github/downloads/indradprasetya/yt-music-webkit/Music-Apple-Silicon.dmg?style=for-the-badge&color=44cc11&label=Apple%20Silicon%20downloads&displayAssetName=false)](https://github.com/indradprasetya/yt-music-webkit/releases)
[![Intel downloads](https://img.shields.io/github/downloads/indradprasetya/yt-music-webkit/Music-Intel.dmg?style=for-the-badge&color=44cc11&label=Intel%20downloads&displayAssetName=false)](https://github.com/indradprasetya/yt-music-webkit/releases)

Music is an unofficial YouTube Music app for macOS, built with Swift and WebKit. It opens the YouTube Music website in its own window, where you can sign in and access your library and playlists. You can play, pause, and change tracks from macOS Now Playing.

Your music keeps playing when you close the window. Click the Music icon in the Dock to reopen it, or press Command-Q to quit the app. Available for Apple Silicon and Intel Macs.

The ⓘ button in the top-right title bar shows the installed version and update status. Music checks for updates about once a day while running, remembering the last check across launches. You can check manually, turn automatic checks off, or download and install an update from this menu. Installation restarts Music after you confirm.

## Download

[See GitHub Releases](https://github.com/indradprasetya/yt-music-webkit/releases)

The download badges count DMGs only, starting with 1.1.1. Update checks and checksum access are excluded; earlier releases used different filenames.

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
git tag -a 1.1.2 -m "Music 1.1.2"
bash scripts/release.sh --version
bash scripts/release.sh
```

The tag sets the app version (legacy `music-X.Y.Z` tags are also recognized). The number of commits reachable from the tagged commit sets the build number, shared by Apple Silicon and Intel. The script requires a clean working tree and rejects versions or build numbers that do not increase over other local release tags. Keep release history intact; rebuilding the same tag keeps the same build number.

Releases require Xcode, a Developer ID Application certificate, notarization credentials in the `music-notary` Keychain profile, and the Sparkle signing key for `com.dyan.ytmusicwebkit`. To select another profile or an explicit tag, use `bash scripts/release.sh <profile> <tag>`.

The script builds, signs, notarizes, and verifies both DMGs, then writes appcasts with their signatures and checksums to `updates/`. Apps starting with 1.1.1 read these feeds through GitHub Raw; no GitHub Actions or Pages deployment is needed.

Push the release tag and create a draft release. Upload the four files from the printed upload folder: `Music-Apple-Silicon.dmg`, `Music-Intel.dmg`, `appcast-arm64.xml`, and `appcast-x86_64.xml`. Keep these filenames unchanged. Publish the release and mark it Latest, then immediately commit and push the generated `updates/` files to `main`. Publish the DMGs before updating the repository feeds so the download URLs are available when clients discover the update.

The release XML copies preserve updates for apps older than 1.1.1, which still use the Latest release's feeds. Keep including them in future releases while supporting those clients. They do not affect the DMG-specific download badges. `updates/SHA256SUMS.txt` stays in the repository and does not need to be uploaded as an asset.
