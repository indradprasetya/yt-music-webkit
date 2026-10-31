#!/usr/bin/env python3
"""Exercise extension settings and reload feedback without changing Safari preferences."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-settings-check-") as directory:
    work = Path(directory)
    source = work / "main.swift"
    source.write_text(r'''
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
@MainActor func check() async throws {
let icons = MusicAppIcons(storageURL: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("icons.plist"))
let extensions = MusicExtensions()
var reloads = 0
let settings = MusicSettings(icons: icons, extensions: extensions, reloadPage: { reloads += 1 })
settings.show()
let window = settings.window!
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let tabs = descendants(window.contentView!).compactMap { $0 as? NSTabView }.first!
tabs.selectTabViewItem(at: 1)
window.contentView!.layoutSubtreeIfNeeded()
let deadline = Date(timeIntervalSinceNow: 10)
while extensions.isWorking && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
assert(!extensions.isWorking)
let host = tabs.selectedTabViewItem!.view!
let content = host.subviews.first as! NSStackView
for view in content.arrangedSubviews where !view.isHidden {
    assert(host.bounds.contains(host.convert(view.bounds, from: view)), "Every setting and action must fit inside the tab")
}
let views = descendants(tabs.selectedTabViewItem!.view!)
let buttons = views.compactMap { $0 as? NSButton }
assert(buttons.contains { $0.title == "Refresh List" && $0.toolTip != nil })
let apply = buttons.first { $0.title == "Apply Extensions" }!
assert(apply.isEnabled)
apply.performClick(nil)
assert(reloads == 1 && window.isVisible, "Apply reloads the page without closing Settings")
assert(!apply.isEnabled, "Do not start duplicate reloads")
apply.performClick(nil)
assert(reloads == 1)
settings.pageLoadFinished()
assert(apply.isEnabled && window.isVisible && tabs.selectedTabViewItem?.identifier as? String == "extensions")
assert(descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Changes applied." })
apply.performClick(nil)
settings.pageLoadFinished(error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"]))
assert(apply.isEnabled && window.isVisible, "A failed navigation must allow retry without losing Settings")
assert(descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Offline") })

let resources = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("native-extension")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try Data(#"{"manifest_version":3,"name":"Native Example","version":"1.0","permissions":["nativeMessaging"]}"#.utf8).write(to: resources.appendingPathComponent("manifest.json"))
    let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: resources))
    extensions.webExtensionController(extensions.controller, sendMessage: ["name": "REQ_PLATFORM"], toApplicationWithIdentifier: "app", for: context) { reply, error in
        assert(reply == nil && error?.localizedDescription.contains("Music") == true)
    }
    print("PASS: Refresh List, Apply stays open, reload retry, and explicit native messaging limitation")
    if CommandLine.arguments.count > 2 {
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView!.layoutSubtreeIfNeeded()
            let view = window.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("extensions-\(name).png"))
        }
    }
    window.close()
}
Task { @MainActor in
    do { try await check(); exit(0) }
    catch { fatalError("Settings check failed: \(error)") }
}
RunLoop.main.run()
''')
    binary = work / "check-settings"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
                    *[str(root / f"Music/{name}.swift") for name in ("MusicAppIcons", "MusicExtensions", "MusicSettings")],
                    str(source), "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    subprocess.run([str(binary), str(work), *sys.argv[1:]], check=True, timeout=20)
