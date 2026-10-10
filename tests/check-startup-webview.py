#!/usr/bin/env python3
"""Run the real startup WebView against local HTTP; --preview also saves screenshots."""
import http.server
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
pages = root / "docs/messages"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        scenario, name = self.path.strip("/").split("/", 1)
        status, mime = 200, "text/html"
        if name == "manifest.json":
            rule = {"enabled": scenario != "disabled", "page": "welcome.html"}
            if scenario in {"disabled", "missing", "empty", "redirect", "slow", "once"}:
                rule["id"] = "once-warning"
            elif scenario == "once-new":
                rule["id"] = "next-warning"
            body = json.dumps({"schemaVersion": 1, "rules": [rule]}).encode()
            if scenario == "updated":
                body = (pages / "manifest.json").read_bytes()
            mime = "application/json"
        elif name == "channels4_profile.jpg":
            body = (pages / name).read_bytes()
            mime = "image/jpeg"
        elif name == "message.css":
            body = (pages / name).read_bytes()
            mime = "text/css"
        else:
            body = (pages / ("updated.html" if scenario == "updated" else "welcome.html")).read_bytes()
            if scenario == "missing":
                status = 404
            elif scenario == "empty":
                body = b"<html><body></body></html>"
            elif scenario == "slow":
                time.sleep(6)
            elif scenario == "redirect":
                self.send_response(302)
                self.send_header("Location", "/success/welcome.html")
                self.end_headers()
                return
            elif scenario == "actions":
                body = body.replace(b"</nav>", b'<a href="music-action://update">Update Now</a></nav>')
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass


checks = r'''
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
window.title = "Music — startup preview"
window.titlebarAppearsTransparent = true
window.center()
let original = NSView(frame: window.contentView!.frame)
window.contentView = original
window.makeKeyAndOrderFront(nil)
let domain = "MusicStartupWebViewCheck.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: domain)!
var updateCount = 0
var whatsNewCount = 0
let messages = MusicStartupMessages(window: window, onUpdate: { updateCount += 1 },
                                    onWhatsNew: { whatsNewCount += 1 })
let base = CommandLine.arguments[1]
let preview = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

Task { @MainActor in
    @MainActor func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<250 {
            if condition() { return }
            try! await Task.sleep(nanoseconds: 25_000_000)
        }
        fatalError("Startup page did not reach expected state")
    }
    @MainActor func start(_ scenario: String) {
        messages.start(version: "1.1.3", manifestURL: URL(string: "\(base)/\(scenario)/manifest.json")!, defaults: defaults)
    }
    @MainActor func page() -> WKWebView { window.contentView!.subviews.first as! WKWebView }
    @MainActor func js(_ source: String) async -> Any? { try! await page().evaluateJavaScript(source) }
    @MainActor func expectJS(_ source: String) async {
        let value = await js(source)
        assert(value as? Bool == true, source)
    }
    @MainActor func snapshot(_ filename: String) async {
        let image = try! await page().takeSnapshot(configuration: nil)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: filename))
    }
    start("success")
    await waitFor { window.contentView !== original }
    assert(page().configuration.websiteDataStore.isPersistent == false)
    assert(page().configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
    await expectJS("document.querySelector('img').naturalWidth > 0")
    await expectJS("document.documentElement.scrollWidth <= innerWidth")
    await expectJS("document.querySelector('h1').innerText === 'Thanks for using'")
    await expectJS("getComputedStyle(document.documentElement).backgroundColor === 'rgb(3, 3, 3)'")
    if let preview {
        try! await Task.sleep(nanoseconds: 300_000_000)
        await snapshot("\(preview)/desktop.png")
        window.setContentSize(NSSize(width: 640, height: 580))
        window.contentView!.layoutSubtreeIfNeeded()
        try! await Task.sleep(nanoseconds: 300_000_000)
        await expectJS("document.documentElement.scrollWidth <= innerWidth")
        await snapshot("\(preview)/small-window.png")
    }
    _ = await js("document.querySelector('a[href=\"music-action://continue\"]').click()")
    await waitFor { window.contentView === original }
    assert(defaults.string(forKey: MusicStartupRules.versionKey) == "1.1.3")
    start("actions")
    await waitFor { window.contentView !== original }
    _ = await js("document.querySelector('a[href=\"music-action://update\"]').click()")
    await waitFor { updateCount == 1 }
    assert(window.contentView !== original, "Update must leave Continue available")
    messages.dismiss()
    defaults.set("1.1.2", forKey: MusicStartupRules.versionKey)
    start("updated")
    await waitFor { window.contentView !== original }
    await expectJS("document.querySelector('h1').innerText === 'Thanks for updating'")
    await expectJS("getComputedStyle(document.documentElement).backgroundColor === 'rgb(3, 3, 3)'")
    await expectJS("document.querySelector('.whats-new').getBoundingClientRect().top < document.querySelector('.actions').getBoundingClientRect().top")
    await expectJS("document.querySelector('.readme').innerText === 'View Music pages'")
    if let preview {
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.contentView!.layoutSubtreeIfNeeded()
        try! await Task.sleep(nanoseconds: 300_000_000)
        await snapshot("\(preview)/updated-desktop.png")
        window.setContentSize(NSSize(width: 640, height: 580))
        window.contentView!.layoutSubtreeIfNeeded()
        try! await Task.sleep(nanoseconds: 300_000_000)
        await expectJS("document.documentElement.scrollWidth <= innerWidth")
        await snapshot("\(preview)/updated-small-window.png")
    }
    _ = await js("document.querySelector('.whats-new').click()")
    await waitFor { whatsNewCount == 1 }
    assert(window.contentView !== original, "What's New must leave the startup page available")
    _ = await js("document.querySelector('a[href=\"music-action://continue\"]').click()")
    await waitFor { window.contentView === original }
    start("success")
    await waitFor { window.contentView !== original }
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil,
                                 characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    app.postEvent(escape, atStart: true)
    await waitFor { window.contentView === original }
    for scenario in ["disabled", "missing", "empty", "redirect", "slow"] {
        start(scenario)
        try! await Task.sleep(nanoseconds: 6_200_000_000)
        assert(window.contentView === original, "\(scenario) must silently keep Music visible")
        assert(!defaults.bool(forKey: MusicStartupRules.shownKeyPrefix + "once-warning"),
               "\(scenario) must not consume a message that was never shown")
    }
    start("slow")
    messages.cancelPending()
    window.orderOut(nil)
    try! await Task.sleep(nanoseconds: 500_000_000)
    assert(window.contentView === original)
    assert(!defaults.bool(forKey: MusicStartupRules.shownKeyPrefix + "once-warning"))
    window.makeKeyAndOrderFront(nil)
    start("once")
    await waitFor { window.contentView !== original }
    assert(defaults.bool(forKey: MusicStartupRules.shownKeyPrefix + "once-warning"),
           "Only a presented message is marked shown")
    messages.dismiss()
    let reopened = MusicStartupMessages(window: window, onUpdate: {}, onWhatsNew: {})
    reopened.start(version: "1.1.3", manifestURL: URL(string: "\(base)/once/manifest.json")!,
                   defaults: UserDefaults(suiteName: domain)!)
    try! await Task.sleep(nanoseconds: 6_200_000_000)
    assert(window.contentView === original, "A previously shown ID must stay hidden after reopening")
    start("once-new")
    await waitFor { window.contentView !== original }
    assert(defaults.bool(forKey: MusicStartupRules.shownKeyPrefix + "next-warning"))
    messages.dismiss()
    defaults.removePersistentDomain(forName: domain)
    print("PASS: welcome/update routing, hosted CSS, actions, once-per-ID display, and retries after silent failures")
    exit(0)
}
app.run()
'''

with tempfile.TemporaryDirectory(prefix="music-startup-webview-") as directory:
    work = Path(directory)
    app = work / "StartupCheck.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "invalid.example.music-startup-check",
        "CFBundleExecutable": "StartupCheck",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }))
    script = work / "main.swift"
    script.write_text(checks)
    binary = app / "MacOS/StartupCheck"
    subprocess.run(["xcrun", "swiftc", str(root / "Music/MusicStartupRules.swift"),
                    str(root / "Music/MusicStartupMessages.swift"), str(script), "-o", str(binary)], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    arguments = [str(binary), f"http://127.0.0.1:{server.server_port}"]
    if "--preview" in sys.argv:
        preview = root / "dist/startup-preview"
        preview.mkdir(parents=True, exist_ok=True)
        arguments.append(str(preview))
    try:
        subprocess.run(arguments, check=True, timeout=60)
    finally:
        server.shutdown()
