#!/usr/bin/env python3
"""Check title-bar color tracking using the resolved Sparkle framework; no app release or network needed."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
frameworks = Path(os.environ.get("MUSIC_TEST_FRAMEWORKS", root / "dist/updater-build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"))
assert (frameworks / "Sparkle.framework").exists(), "Resolve Sparkle first, or set MUSIC_TEST_FRAMEWORKS"
checks = r'''
DispatchQueue.main.async {
    let window = app.windows.first { $0.contentView is WKWebView }!
    let web = window.contentView as! WKWebView
    assert(window.titlebarAppearsTransparent)
    let initial = web.underPageBackgroundColor.usingColorSpace(.deviceRGB)!
    let background = window.backgroundColor.usingColorSpace(.deviceRGB)!
    assert(abs(initial.redComponent - background.redComponent) < 0.01, "Match the initial loading background")
    let colors = [255, 3, 255]
    var stage = 0
    func loadColor() {
        web.loadHTMLString("<html style='background:rgb(\(colors[stage]),\(colors[stage]),\(colors[stage]))'><body>Background check</body></html>", baseURL: nil)
    }
    loadColor()
    let deadline = Date().addingTimeInterval(15)
    _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
        let actual = window.backgroundColor.usingColorSpace(.deviceRGB)!
        if !web.isLoading && abs(actual.redComponent - CGFloat(colors[stage]) / 255) < 0.01 {
            stage += 1
            if stage == colors.count {
                timer.invalidate()
                print("PASS: transparent title bar follows initial, white, dark, and returning white backgrounds")
                exit(0)
            }
            loadColor()
        }
        if Date() > deadline { fatalError("Title bar did not follow background at stage \(stage)") }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="music-window-check-") as directory:
    work = Path(directory)
    app = work / "WindowCheck.app/Contents"
    (app / "MacOS").mkdir(parents=True)
    info = plistlib.loads((root / "Music/Info.plist").read_bytes())
    info.update(CFBundleIdentifier="com.dyan.music-window-check", CFBundleExecutable="WindowCheck",
                CFBundleName="WindowCheck", CFBundleVersion="1", CFBundleShortVersionString="1.1.1",
                SUEnableAutomaticChecks=False)
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    source = (root / "Music/main.swift").read_text()
    source = source.replace('webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))',
                            'webView.loadHTMLString("", baseURL: nil)')
    script = work / "main.swift"
    script.write_text(source.replace("NSApp.activate(ignoringOtherApps: true)",
                                     "NSApp.activate(ignoringOtherApps: true)\n" + checks))
    binary = app / "MacOS/WindowCheck"
    subprocess.run(["xcrun", "swiftc", "-F", str(frameworks), "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", str(frameworks), str(script),
                    str(root / "Music/MusicUpdates.swift"), str(root / "Music/MusicReleaseNotes.swift"),
                    "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    subprocess.run([str(binary)], check=True, timeout=20)
