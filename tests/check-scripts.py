#!/usr/bin/env python3
"""Check local script storage, validation, and real WebKit execution offline."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-scripts-check-") as directory:
    work = Path(directory)
    source = work / "main.swift"
    source.write_text(r'''
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
@MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fatalError("Offline fixture failed: \(error)")
    }
}
@MainActor func check() async throws {
    let work = URL(fileURLWithPath: CommandLine.arguments[1])
    let storage = work.appendingPathComponent("saved/CustomScripts.plist")
    let file = work.appendingPathComponent("example.js")
    let code = "\"use strict\"; document.documentElement.dataset.customScript = 'ran'; document.documentElement.dataset.strictScript = String((function () { return this === undefined; })());"
    try Data(code.utf8).write(to: file)
    let scripts = MusicScripts(storageURL: storage)
    try scripts.importScript(from: file)
    assert(scripts.entries.count == 1 && !scripts.entries[0].isEnabled, "Imports must start OFF")
    let id = scripts.entries[0].id
    let controller = WKUserContentController()
    let builtIn = WKUserScript(source: "document.documentElement.dataset.builtIn = 'kept';", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    controller.addUserScript(builtIn)
    scripts.apply(to: controller)
    assert(controller.userScripts.count == 1, "Importing must never register disabled scripts")
    try scripts.setEnabled(true, for: id)
    scripts.apply(to: controller)
    scripts.apply(to: controller)
    assert(controller.userScripts.count == 2 && controller.userScripts[0] === builtIn, "Reapplying preserves built-ins without duplicate injection")
    let restored = MusicScripts(storageURL: storage)
    assert(restored.entries == scripts.entries && restored.entries[0].isEnabled, "Save explicit activation across restarts")
    try FileManager.default.removeItem(at: file)
    assert(MusicScripts(storageURL: storage).entries.count == 1, "Keep a local copy independent of the import")

    let before = try Data(contentsOf: storage)
    let invalid: [(String, Data)] = [
        ("wrong.txt", Data(code.utf8)), ("empty.js", Data(" \n".utf8)),
        ("encoding.js", Data([0xff, 0xfe])), ("syntax.js", Data("const = ;".utf8)),
        ("large.js", Data(repeating: 32, count: 1_048_577)),
        ("grant.user.js", Data("// ==UserScript==\n// @grant GM_getValue\n// ==/UserScript==\n\(code)".utf8)),
        ("grant-crlf.user.js", Data("// ==UserScript==\r\n// @grant GM_getValue\r\n// ==/UserScript==\r\n\(code)".utf8)),
        ("dependency.user.js", Data("// ==UserScript==\n// @require https://example.com/lib.js\n// ==/UserScript==\n\(code)".utf8)),
        ("other-site.user.js", Data("// ==UserScript==\n// @match https://example.com/*\n// ==/UserScript==\n\(code)".utf8)),
        ("exclude.user.js", Data("// ==UserScript==\n// @exclude *private*\n// ==/UserScript==\n\(code)".utf8)),
        ("unclosed.user.js", Data("// ==UserScript==\n// @name Incomplete\n\(code)".utf8)),
    ]
    for (name, data) in invalid {
        let url = work.appendingPathComponent(name)
        try data.write(to: url)
        do { try scripts.importScript(from: url); fatalError("Accepted invalid or unsupported script: \(name)") }
        catch { }
        assert(scripts.entries.count == 1)
        let after = try Data(contentsOf: storage)
        assert(after == before, "Rejected imports must preserve saved scripts")
    }
    let userScript = work.appendingPathComponent("supported.user.js")
    try Data("// ==UserScript==\r\n// @name Early DOM\r\n// @grant none\r\n// @match https://music.youtube.com/*\r\n// @run-at document-start\r\n// ==/UserScript==\r\nthrow new Error('compile only; never execute during import');".utf8).write(to: userScript)
    try scripts.importScript(from: userScript)
    assert(scripts.entries[1].name == "Early DOM" && scripts.entries[1].runAtStart && !scripts.entries[1].isEnabled)
    do { try scripts.importScript(from: userScript); fatalError("Accepted duplicate script") }
    catch { }

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = controller
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    let navigation = Navigation()
    webView.navigationDelegate = navigation
    for (base, expected) in [
        ("https://music.youtube.com/", "ran"),
        ("https://accounts.google.com/", "missing"),
        ("https://music.youtube.com.example.com/", "missing"),
        ("http://music.youtube.com/", "missing"),
        ("https://music.youtube.com:8443/", "missing"),
    ] {
        navigation.finished = false
        webView.loadHTMLString("<!doctype html><html><body>Offline fixture</body></html>", baseURL: URL(string: base))
        for _ in 0..<500 {
            if navigation.finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        assert(navigation.finished, "Fixture navigation must complete")
        let result = try await webView.evaluateJavaScript("document.documentElement.dataset.customScript || 'missing'") as! String
        assert(result == expected, "Scripts must run only at the exact HTTPS YouTube Music origin: \(base)")
        if expected == "ran" {
            let strict = try await webView.evaluateJavaScript("document.documentElement.dataset.strictScript") as! String
            assert(strict == "true", "Preserve the imported script's strict-mode directive")
        }
        let native = try await webView.evaluateJavaScript("document.documentElement.dataset.builtIn") as! String
        assert(native == "kept", "Custom scripts must preserve Music's built-in integration")
    }
    try scripts.setEnabled(false, for: id)
    scripts.apply(to: controller)
    assert(controller.userScripts.count == 1 && controller.userScripts[0] === builtIn)
    let original = try Data(contentsOf: userScript)
    try scripts.remove(id: scripts.entries[1].id)
    let remainingOriginal = try Data(contentsOf: userScript)
    assert(remainingOriginal == original, "Remove only the imported copy")
    try scripts.remove(id: id)
    assert(MusicScripts(storageURL: storage).entries.isEmpty)
    let blocked = work.appendingPathComponent("not-a-folder")
    try Data().write(to: blocked)
    let unwritable = MusicScripts(storageURL: blocked.appendingPathComponent("scripts.plist"))
    do { try unwritable.importScript(from: userScript); fatalError("Accepted failed persistence") }
    catch { }
    assert(unwritable.entries.isEmpty)
    try Data("corrupt preferences".utf8).write(to: storage)
    let corrupt = MusicScripts(storageURL: storage)
    assert(corrupt.loadError != nil && corrupt.entries.isEmpty)
    do { try corrupt.importScript(from: userScript); fatalError("Overwrote unreadable saved scripts") }
    catch { }
    let untouched = try String(contentsOf: storage, encoding: .utf8)
    assert(untouched == "corrupt preferences")
    print("PASS: default OFF, persistence, validation, atomic failures, safe removal, origin restrictions, and preserved built-ins")
}
Task { @MainActor in
    do { try await check(); exit(0) }
    catch { fatalError("Script check failed: \(error)") }
}
RunLoop.main.run()
''')
    binary = work / "check-scripts"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(root / "Music/MusicScripts.swift"),
                    str(source), "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    subprocess.run([str(binary), str(work)], check=True, timeout=25)
