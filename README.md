# Music — YouTube Music for macOS

[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fapi.github.com%2Frepos%2Findradprasetya%2Fyt-music-webkit%2Freleases%2Flatest&query=%24.tag_name&label=version&color=0088cc&style=for-the-badge)](https://github.com/indradprasetya/yt-music-webkit/releases)
[![Downloads](https://img.shields.io/github/downloads/indradprasetya/yt-music-webkit/total?style=for-the-badge&color=44cc11&label=downloads)](https://github.com/indradprasetya/yt-music-webkit/releases)

Music is a lightweight YouTube Music app for macOS, built with Swift and WebKit. Available for Apple Silicon and Intel Macs, with native playback controls and automatic update checks.

Music is designed with privacy and security in mind. It has no developer-operated backend and sends no personal data, analytics, or listening history to the developer. Official installers are signed and notarized, and update signatures are verified before installation. See [Privacy](#privacy) for details.

<p align="center">
  <img src="docs/screenshots/music-window.png" alt="YouTube Music playing in the native macOS Music window" width="75%" style="display: block; margin: 0 auto;">
</p>

## Download

[![Download latest version for Apple Silicon](https://img.shields.io/badge/Download_latest-Apple_Silicon-0969da?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/indradprasetya/yt-music-webkit/releases/download/v1.1.2/Music-1.1.2-Apple-Silicon.dmg)<br>
<span style="font-size: 0.8em;">For Macs with Apple Silicon chips: M1, M2, M3, and later.</span>


[![Download latest version for Intel](https://img.shields.io/badge/Download_latest-Intel-0969da?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/indradprasetya/yt-music-webkit/releases/download/v1.1.2/Music-1.1.2-Intel.dmg)<br>
<span style="font-size: 0.8em;">For Macs with an Intel processor.</span>

[See GitHub Releases](https://github.com/indradprasetya/yt-music-webkit/releases)

## Features

- **Native Controls menu:** Control playback, volume, and mute, or choose Shuffle and Repeat Off, All, or One. Shuffle and Repeat stay in sync with YouTube Music.
- **Background playback:** Music keeps playing when you close the window. Click the Dock icon to reopen it, or press Command-Q to quit.
- **macOS Now Playing:** Play, pause, and change tracks from the system's playback controls.
<p>
  <img src="docs/screenshots/now-playing.png" alt="macOS Now Playing controls with album artwork, playback controls, and track progress" width="50%">
</p>

## Privacy

Music does not collect personal data or send analytics, telemetry, or listening history to the developer. The app has no developer-operated backend.

Music displays the YouTube Music website using WebKit. Google/YouTube may collect and process data when you sign in, listen, or interact with the service, as described in [Google's Privacy Policy](https://policies.google.com/privacy). WebKit stores cookies and website data locally on your Mac to maintain your session.

Update checks, installer downloads, and What's New contact GitHub. These requests share standard connection information, such as your IP address, with GitHub under its [Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

Official release installers are signed with an Apple Developer ID and notarized by Apple. Sparkle verifies update signatures before installation.


## License

Copyright © 2026 indradprasetya.

Music's source code is licensed under the **GNU General Public License version 3 only** (`GPL-3.0-only`). You may use, modify, and redistribute it under the terms of [LICENSE](LICENSE). It is provided without warranty.

When distributing Music or a modified version, provide the corresponding source code under GPLv3. See [Build and release](#build-and-release) for instructions.

Third-party components retain their own licenses. [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) contains the notices for Sparkle and its bundled components. Both license files are included in the app's `Contents/Resources` directory.

Music is not affiliated with or endorsed by Google or YouTube. YouTube Music, its branding, and the content accessed through the service are not covered by this project's license and remain subject to their respective owners' rights and the [YouTube Terms of Service](https://www.youtube.com/static?template=terms).
