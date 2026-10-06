#!/usr/bin/env python3
"""Build first as documented in BUILD.md, then run python3 tests/check-updates.py."""
import functools
import http.server
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
frameworks = root / "dist/updater-build/Build/Products/Debug"
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
let domain = Bundle.main.bundleIdentifier!
UserDefaults.standard.removePersistentDomain(forName: domain)
let expected = CommandLine.arguments[1]
let updates = MusicUpdates()
assert(updates.menu.items[0].title == "Music 1.1.0", "Only the marketing version should be visible")
assert(updates.updater.automaticallyChecksForUpdates)
assert(!updates.updater.automaticallyDownloadsUpdates)
updates.toggleAutomaticChecks()
assert(!MusicUpdates().updater.automaticallyChecksForUpdates, "Preference must persist")
if expected != "Not checked yet" { updates.toggleAutomaticChecks() }
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
updates.attach(to: window)
let deadline = Date().addingTimeInterval(10)
let earliest = Date().addingTimeInterval(0.5)
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let status = updates.menu.items[1].title
    if Date() > earliest && status == expected {
        if expected == "Update available" {
            assert(!updates.menu.items[2].isHidden)
            assert(updates.menu.items[2].title == "Update to 1.1.0…", "Show the marketing version even for a newer internal build")
            assert(updates.button.toolTip == "A Music update is available")
            assert(updates.updater.canCheckForUpdates, "User must be able to open the pending update")
        } else {
            assert(updates.menu.items[2].isHidden)
        }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        print("PASS: \(expected)")
        exit(0)
    }
    if Date() > deadline { fatalError("Expected \(expected), got \(status)") }
}
app.run()
''')
    subprocess.run(["xcrun", "swiftc", "-F", str(frameworks), "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                    str(root / "Music/MusicUpdates.swift"), str(work / "main.swift"),
                    "-o", str(app / "MacOS/UpdateCheck")], env=env, check=True)
    feed = '''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Music</title><item><title>Music 1.1.0</title><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString><enclosure url="https://example.com/Music.dmg" length="100" type="application/octet-stream"/></item></channel></rss>'''
    try:
        for expected, data in [("Up to date", feed.format(build=5)),
                               ("Update available", feed.format(build=6)),
                               ("Couldn’t check for updates", "invalid XML"),
                               ("Not checked yet", feed.format(build=6))]:
            for arch in ("arm64", "x86_64"):
                (work / f"appcast-{arch}.xml").write_text(data)
            requests.clear()
            subprocess.run([str(app / "MacOS/UpdateCheck"), expected], check=True, timeout=15)
            assert len(requests) == (0 if expected == "Not checked yet" else 1), requests
        server.shutdown()
        server.server_close()
        subprocess.run([str(app / "MacOS/UpdateCheck"), "Couldn’t check for updates"], check=True, timeout=15)
    finally:
        server.server_close()
