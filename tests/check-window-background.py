#!/usr/bin/env python3
"""Check live title-bar layout using an offline page and the resolved Sparkle framework."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
frameworks = Path(os.environ.get("MUSIC_TEST_FRAMEWORKS", root / "dist/updater-build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"))
assert (frameworks / "Sparkle.framework").exists(), "Resolve Sparkle first, or set MUSIC_TEST_FRAMEWORKS"
checks = r'''
DispatchQueue.main.async {
    let window = app.windows.first { $0.contentView is TitlebarBackgroundView }!
    let background = window.contentView as! TitlebarBackgroundView
    let web = background.webView
    assert(window.titlebarAppearsTransparent)
    assert(window.styleMask.contains(.fullSizeContentView))
    for size in [NSSize(width: 1200, height: 800), NSSize(width: 1000, height: 700)] {
        window.setContentSize(size)
        background.layoutSubtreeIfNeeded()
        let frame = background.convert(web.bounds, from: web)
        assert(frame == background.convert(window.contentLayoutRect, from: nil),
               "Keep the page inside the native content area when resizing")
        let hit = background.hitTest(NSPoint(x: frame.midX, y: frame.midY))!
        assert(hit === web || hit.isDescendant(of: web), "The live copy must not intercept page input")
        let titlebarHit = background.hitTest(NSPoint(x: frame.midX, y: frame.maxY + 2))
        assert(titlebarHit !== web && titlebarHit?.isDescendant(of: web) != true,
               "The title bar must not contain duplicate interactive controls")
    }
    if CommandLine.arguments.contains("--layout-only") {
        print("PASS: native title-bar/content separation, resizing, and hit testing")
        exit(0)
    }
    let html = """
        <!doctype html><html style="background:black;overflow-y:scroll">
        <style>
        * { box-sizing:border-box }
        ::-webkit-scrollbar { width:18px; background:black }
        body { margin:0 }
        header { height:80px;border-top:1px solid black;background:linear-gradient(to right,red,blue) }
        </style>
        <body><main><div style="min-height:200vh"><header>Visible controls</header></div></main></body></html>
        """
    web.loadHTMLString(html, baseURL: URL(string: "https://music.youtube.com/"))
    let deadline = Date().addingTimeInterval(15)
    var stage = 0
    var checking = false
    _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
        if Date() > deadline { fatalError("Window layout did not settle at stage \(stage)") }
        guard !web.isLoading, !checking else { return }
        let expectedGutter: CGFloat = stage == 2 ? 0 : 18
        let gutter = web.bounds.width * (1 - background.contentWidthFraction)
        guard abs(gutter - expectedGutter) < 0.5 else { return }
        checking = true
        web.evaluateJavaScript("""
            ({width:innerWidth, height:innerHeight, top:document.querySelector('header').getBoundingClientRect().top})
            """) { value, error in
            assert(error == nil)
            let viewport = value as! [String: Double]
            assert(abs(viewport["width"]! - web.bounds.width) < 1)
            assert(abs(viewport["height"]! - web.bounds.height) < 1)
            assert(viewport["top"]! == 0, "Page controls must not be shifted or cropped")
            let frame = background.convert(web.bounds, from: web)
            assert(frame == background.convert(window.contentLayoutRect, from: nil),
                   "Keep the whole page and its scrollbar inside the native content area")
            let hit = background.hitTest(NSPoint(x: frame.midX, y: frame.midY))!
            assert(hit === web || hit.isDescendant(of: web), "The live copy must not intercept page input")
            let titlebarHit = background.hitTest(NSPoint(x: frame.midX, y: frame.maxY + 2))
            assert(titlebarHit !== web && titlebarHit?.isDescendant(of: web) != true,
                   "The title bar must not contain duplicate interactive controls")
            if stage == 0 {
                stage = 1
                web.evaluateJavaScript("""
                    document.documentElement.style.overflow = 'hidden';
                    document.querySelector('main').style.cssText = 'height:100vh;overflow-y:scroll';
                    document.querySelector('header').style.background = 'linear-gradient(to right,lime,blue)';
                    """) { _, error in assert(error == nil); checking = false }
                window.setContentSize(NSSize(width: 1000, height: 700))
            } else if stage == 1 {
                stage = 2
                web.evaluateJavaScript("document.querySelector('main').style.overflow = 'hidden'") {
                    _, error in assert(error == nil); checking = false
                }
            } else {
                timer.invalidate()
                print("PASS: controls and scrollbar remain below the title bar; root/nested gutters, resize, and hit testing")
                exit(0)
            }
        }
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
    source = source.replace('webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))', '')
    script = work / "main.swift"
    script.write_text(source.replace("NSApp.activate(ignoringOtherApps: true)",
                                     "NSApp.activate(ignoringOtherApps: true)\n" + checks))
    binary = app / "MacOS/WindowCheck"
    subprocess.run(["xcrun", "swiftc", "-F", str(frameworks), "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", str(frameworks), str(script),
                    str(root / "Music/MusicUpdates.swift"), str(root / "Music/MusicReleaseNotes.swift"),
                    "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    subprocess.run([str(binary), *sys.argv[1:]], check=True, timeout=20)
