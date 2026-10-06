# Music

[![Version](https://img.shields.io/badge/version-v1.0.2-0088cc?style=for-the-badge)](https://github.com/indradprasetya/yt-music-webkit/releases)
[![Downloads](https://img.shields.io/github/downloads/indradprasetya/yt-music-webkit/total?style=for-the-badge&color=44cc11)](https://github.com/indradprasetya/yt-music-webkit/releases)

Music is an unofficial YouTube Music app for macOS, built with Swift and WebKit. It opens the YouTube Music website in its own window, where you can sign in and access your library and playlists. You can play, pause, and change tracks from macOS Now Playing.

Your music keeps playing when you close the window. Click the Music icon in the Dock to reopen it, or press Command-Q to quit the app. Available for Apple Silicon and Intel Macs.

## Download

[See GitHub Releases](https://github.com/indradprasetya/yt-music-webkit/releases)

## Development

Open `Music.xcodeproj` in Xcode 16 or newer, select the **Music** scheme and **My Mac**, then press **Command-R**. The app targets macOS 12 or newer and uses local ad-hoc signing, so no Apple Developer team is required to run it.

Source code and app resources live in `Music/`. See [BUILD.md](BUILD.md) for terminal builds and DMG packaging.

## Screenshots

### Music window

![YouTube Music playing in the native macOS Music window](docs/screenshots/music-window.png)

### macOS Now Playing

![macOS Now Playing controls with album artwork, playback controls, and track progress](docs/screenshots/now-playing.png)
