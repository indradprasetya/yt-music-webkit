#!/usr/bin/env python3
"""Exercise extension settings and reload feedback without changing Safari preferences."""
from pathlib import Path
import os
import subprocess
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
let scriptStorage = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("scripts.plist")
let scripts = MusicScripts(storageURL: scriptStorage)
let imported = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("test.js")
try Data("document.body.dataset.example = 'enabled';".utf8).write(to: imported)
try scripts.importScript(from: imported)
var reloads = 0
let settings = MusicSettings(icons: icons, extensions: extensions, scripts: scripts, reloadPage: { reloads += 1 })
settings.show()
let window = settings.window!
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let paneController = window.contentViewController as? NSTabViewController
assert(paneController?.tabStyle == .toolbar, "Use macOS's native settings toolbar")
let tabs = paneController!.tabView
assert(window.toolbar?.allowsUserCustomization == false, "Settings navigation must remain stable")
assert(tabs.tabViewItems.map(\.label) == ["App Icon", "Extensions", "Scripts"])
tabs.selectTabViewItem(at: 1)
window.contentView!.layoutSubtreeIfNeeded()
assert(window.title == "Extensions", "The native window title identifies the active pane")
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
let scriptPane = window.toolbar!.items.first { $0.label == "Scripts" }!
assert(NSApp.sendAction(scriptPane.action!, to: scriptPane.target, from: scriptPane))
window.contentView!.layoutSubtreeIfNeeded()
assert(window.title == "Scripts" && tabs.selectedTabViewItem?.identifier as? String == "scripts")
let scriptButtons = descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSButton }
let scriptToggle = scriptButtons.first { $0.identifier?.rawValue == scripts.entries[0].id.uuidString }!
assert(scriptToggle.state == .off, "Imported scripts are OFF in Settings")
scriptToggle.performClick(nil)
assert(scripts.entries[0].isEnabled)
let applyScripts = scriptButtons.first { $0.title == "Apply Scripts" }!
let previousReloads = reloads
let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
assert(window.performKeyEquivalent(with: returnKey), "Return applies the visible pane")
assert(reloads == previousReloads + 1 && window.isVisible && !applyScripts.isEnabled)
assert(!apply.isEnabled, "Do not apply another tab while the shared page is reloading")
settings.pageLoadFinished()
assert(applyScripts.isEnabled && window.isVisible && tabs.selectedTabViewItem?.identifier as? String == "scripts")
let backup = scriptStorage.appendingPathExtension("backup")
try FileManager.default.moveItem(at: scriptStorage, to: backup)
try FileManager.default.createDirectory(at: scriptStorage, withIntermediateDirectories: false)
let savedToggle = descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == scripts.entries[0].id.uuidString }!
savedToggle.performClick(nil)
assert(scripts.entries[0].isEnabled, "A failed toggle must preserve the saved state")
try FileManager.default.removeItem(at: scriptStorage)
try FileManager.default.moveItem(at: backup, to: scriptStorage)
applyScripts.performClick(nil)
assert(descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Reloading YouTube Music…" }, "Apply must replace an earlier operation error with current progress")
settings.pageLoadFinished()
assert(descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Changes applied." })

let resources = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("native-extension")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try Data(#"{"manifest_version":3,"name":"Native Example","version":"1.0","permissions":["nativeMessaging"]}"#.utf8).write(to: resources.appendingPathComponent("manifest.json"))
let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: resources))
extensions.webExtensionController(extensions.controller, sendMessage: ["name": "REQ_PLATFORM"], toApplicationWithIdentifier: "app", for: context) { reply, error in
    assert(reply == nil && error?.localizedDescription.contains("Music") == true)
}
print("PASS: Refresh List, both Apply actions stay open, reload retry, default OFF, and native messaging limitation")
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
                    *[str(root / f"Music/{name}.swift") for name in ("MusicAppIcons", "MusicExtensions", "MusicScripts", "MusicSettings")],
                    str(source), "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    subprocess.run([str(binary), str(work)], check=True, timeout=20)
