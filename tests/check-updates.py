#!/usr/bin/env python3
"""Run against dist/updater-build, or set MUSIC_TEST_FRAMEWORKS to an existing Debug products directory."""
import functools
import http.server
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
frameworks = Path(os.environ.get("MUSIC_TEST_FRAMEWORKS", root / "dist/updater-build/Build/Products/Debug"))
assert (frameworks / "Sparkle.framework").exists(), "Build Debug in dist/updater-build first"
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

with tempfile.TemporaryDirectory(prefix="music-updater-check-") as directory:
    work = Path(directory)
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=directory))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    app = work / "UpdateCheck.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    info = plistlib.loads((root / "Music/Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.dyan.music-updater-check", CFBundleExecutable="UpdateCheck",
                CFBundleName="UpdateCheck", CFBundleVersion="5", CFBundleShortVersionString="1.1.0",
                SUFeedURL=f"http://127.0.0.1:{server.server_port}/appcast.xml")
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    (work / "main.swift").write_text(r'''
import AppKit
import Sparkle

let app = NSApplication.shared
app.mainMenu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu(title: "Music")
app.mainMenu!.addItem(appItem)
let domain = Bundle.main.bundleIdentifier!
UserDefaults.standard.removePersistentDomain(forName: domain)
let expected = CommandLine.arguments[1]
let scenario = CommandLine.arguments[2]
let updates = MusicUpdates()
assert(updates.menu.items.map(\.title) == ["Check for Updates…", "What’s New…"])
assert(updates.menu.items[1].isEnabled && updates.menu.items[1].action != nil, "What's New must open release notes")
assert(updates.updater.automaticallyChecksForUpdates)
assert(!updates.updater.automaticallyDownloadsUpdates)
updates.updater.automaticallyChecksForUpdates = false
assert(!MusicUpdates().updater.automaticallyChecksForUpdates, "Preference must persist")
if scenario != "disabled" { updates.updater.automaticallyChecksForUpdates = true }
if scenario == "recent" || scenario == "manual" {
    UserDefaults.standard.set(Date(), forKey: "SULastCheckTime")
}
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
updates.attach(to: window)
assert(window.titlebarAccessoryViewControllers.isEmpty, "No info button in the title bar")
assert(app.mainMenu!.items.count == 2 && app.mainMenu!.items[1].title == "Updates")
assert(app.mainMenu!.items[1].submenu === updates.menu)
assert(appItem.submenu!.items.isEmpty, "Update actions must live only in Updates")
if scenario == "disabled" {
    let action = updates.menu.items[1].action!
    app.sendAction(action, to: updates, from: nil)
    let panel = app.windows.first { $0 is NSPanel && $0.isVisible }!
    assert(window.attachedSheet == nil && panel.sheetParent == nil, "Release notes must be an independent panel")
    assert(panel.title == "Music 1.1.0")
    let closeButton = panel.standardWindowButton(.closeButton)!
    assert(closeButton.isEnabled && !closeButton.isHidden)
    app.sendAction(action, to: updates, from: nil)
    assert(app.windows.filter { $0 is NSPanel && $0.isVisible }.count == 1, "Reuse the open panel")
    closeButton.performClick(nil)
    assert(!panel.isVisible, "The native close button must dismiss release notes")
    app.sendAction(action, to: updates, from: nil)
    let reopened = app.windows.first { $0 is NSPanel && $0.isVisible }!
    assert(reopened !== panel, "Reopening must start fresh release notes")
    reopened.performClose(nil)
}
if scenario == "manual" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { updates.checkForUpdates() }
}
let deadline = Date().addingTimeInterval(10)
let earliest = Date().addingTimeInterval(2)
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let status = updates.menu.items[0].toolTip ?? ""
    if Date() > earliest && status.hasPrefix(expected) {
        if expected == "Update available" {
            assert(updates.menu.items[0].title == "Update to 1.1.0…", "Show the marketing version even for a newer internal build")
            assert(updates.updater.canCheckForUpdates, "User must be able to open the pending update")
        } else {
            assert(updates.menu.items[0].title == "Check for Updates…")
        }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        print("PASS: \(scenario): \(expected)")
        exit(0)
    }
    if Date() > deadline { fatalError("Expected \(expected), got \(status)") }
}
app.run()
''')
    subprocess.run(["xcrun", "swiftc", "-F", str(frameworks), "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                    str(root / "Music/MusicUpdates.swift"), str(root / "Music/MusicReleaseNotes.swift"), str(work / "main.swift"),
                    "-o", str(app / "MacOS/UpdateCheck")], env=env, check=True)
    feed = '''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Music</title><item><title>Music 1.1.0</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString><enclosure url="https://example.com/Music.dmg" length="100" type="application/octet-stream"/></item></channel></rss>'''
    try:
        for expected, data, scenario in [("Up to date", feed.format(build=5), "scheduled"),
                                         ("Update available", feed.format(build=6), "scheduled"),
                                         ("Couldn’t check for updates", "invalid XML", "scheduled"),
                                         ("Not checked yet", feed.format(build=6), "disabled"),
                                         ("Not checked yet", feed.format(build=6), "recent"),
                                         ("Update available", feed.format(build=6), "manual")]:
            for arch in ("arm64", "x86_64"):
                (work / f"appcast-{arch}.xml").write_text(data)
            requests.clear()
            subprocess.run([str(app / "MacOS/UpdateCheck"), expected, scenario], check=True, timeout=15)
            assert len(requests) == (0 if expected == "Not checked yet" else 1), requests
        server.shutdown()
        server.server_close()
        subprocess.run([str(app / "MacOS/UpdateCheck"), "Couldn’t check for updates", "scheduled"], check=True, timeout=15)
    finally:
        server.server_close()
