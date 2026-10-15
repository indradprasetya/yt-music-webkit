#!/usr/bin/env python3
"""Check installed-extension discovery without changing Safari or user settings."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-extension-check-") as directory:
    work = Path(directory)
    extension = work / "Example.app/Contents/PlugIns/Example.appex"
    resources = extension / "Contents/Resources"
    resources.mkdir(parents=True)
    (extension / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "example.music-extension",
        "CFBundleDisplayName": "Example Music Extension",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.Safari.web-extension"},
    }))
    (resources / "manifest.json").write_text('{"manifest_version":3,"name":"Example","version":"1.0"}')
    raw = subprocess.run(["/usr/bin/pluginkit", "-m", "-vvv", "-p", "com.apple.Safari.web-extension"],
                         capture_output=True, text=True, check=True).stdout
    raw_file = work / "installed.txt"
    raw_file.write_text(raw)
    source = work / "main.swift"
    source.write_text(r'''
import AppKit
import WebKit
let path = CommandLine.arguments[1]
let entries = MusicExtensions.installedExtensions(in: "Path = \(path)\nPath = /missing/Other.appex")
assert(entries.count == 1)
assert(entries[0].id == "example.music-extension")
assert(entries[0].name == "Example Music Extension")
assert(entries[0].url.path == path)
let registered = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let expected = Set(MusicExtensions.installedExtensions(in: registered).map(\.id))
let discovered = Set(MusicExtensions.discover()!.map(\.id))
assert(discovered == expected, "Automatic scanning must find the registered extensions")
Task { @MainActor in
    do {
        let ext = try await WKWebExtension(resourceBaseURL: entries[0].url.appendingPathComponent("Contents/Resources"))
        let controller = WKWebExtensionController()
        let context = WKWebExtensionContext(for: ext)
        try controller.load(context)
        print("PASS: installed-extension discovery and WebKit extension loading")
        exit(0)
    } catch {
        fatalError("Could not load a valid extension: \(error)")
    }
}
RunLoop.main.run()
''')
    binary = work / "check-extensions"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
                    str(root / "Music/MusicExtensions.swift"), str(source), "-o", str(binary)],
                   check=True, env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    subprocess.run([str(binary), str(extension), str(raw_file)], check=True)
