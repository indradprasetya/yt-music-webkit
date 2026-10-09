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
        if stage == 3 {
            checking = true
            web.callAsyncJavaScript("""
                const content = document.querySelector('ytmusic-app-layout > #content');
                const header = document.querySelector('#nav-bar-background');
                const guide = document.querySelector('#mini-guide-background');
                const bar = document.querySelector('#music-scrollbar');
                const settle = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                const check = (condition, message) => { if (!condition) throw new Error(message); };
                check(!!bar, 'Create the overlay scrollbar');
                if (!CSS.supports('animation-timeline: --music-titlebar-scroll')) return {supported: false};
                const samples = [];
                for (const top of [192, 96, 72, 48, 24, 0, 24, 48, 96, 0]) {
                    content.scrollTop = top;
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    samples.push({top: content.scrollTop, header: +getComputedStyle(header).opacity,
                                  guide: +getComputedStyle(guide).opacity});
                    check(Math.abs(bar.scrollTop - content.scrollTop) < 1, 'Page scrolling updates the thumb');
                }
                const bounds = bar.getBoundingClientRect();
                check(content.clientWidth === innerWidth, 'The gradient reaches the right edge without a gutter');
                check(bounds.top === 8 && bounds.right === innerWidth - 4,
                      'Inset the scrollbar below the title bar and away from the window edge');
                check(document.elementFromPoint(bounds.right - 7, bounds.top + 10) === bar,
                      'The header must not cover the scrollbar hit area');
                check(getComputedStyle(bar, '::-webkit-scrollbar-track').backgroundColor === 'rgba(0, 0, 0, 0)',
                      'Do not paint a black track');
                check(bar.tabIndex === 0 && !!bar.getAttribute('aria-label'), 'Keep keyboard access and an accessible name');
                bar.scrollTop = 320;
                await settle();
                check(content.scrollTop === 320, 'Moving the scrollbar scrolls the page');
                const page = content.firstElementChild;
                page.style.height = '600vh';
                content.scrollTop = content.scrollHeight;
                await settle();
                check(Math.abs(bar.scrollTop - content.scrollTop) < 1, 'Growing content must not reset page scroll');
                content.style.height = '400px';
                await settle();
                check(bar.scrollHeight - bar.clientHeight === content.scrollHeight - content.clientHeight,
                      'Keep the scroll range correct after resizing');
                page.style.height = '10px';
                await settle();
                check(bar.hidden, 'Hide the scrollbar when the page fits');
                content.style.height = '';
                page.style.height = '300vh';
                await settle();
                content.style.visibility = 'hidden';
                await settle();
                check(bar.hidden, 'Hide the scrollbar while the player covers the page');
                content.style.visibility = '';
                const replacement = content.cloneNode(true);
                content.replaceWith(replacement);
                await settle();
                check(!bar.hidden, 'Keep the scrollbar when YouTube replaces its scroller');
                const detachedTop = content.scrollTop;
                bar.scrollTop = 240;
                await settle();
                check(replacement.scrollTop === 240, 'Bind the scrollbar to the replacement page');
                check(content.scrollTop === detachedTop, 'Do not scroll the detached page');
                replacement.replaceWith(content);
                await settle();
                return {supported: true, samples,
                        contentRight: content.getBoundingClientRect().left + content.clientWidth,
                        overlayEdges: ['#nav-bar-background', '#nav-bar-divider', 'ytmusic-nav-bar'].map(selector =>
                            document.querySelector(selector).getBoundingClientRect().right),
                        rootOverscroll: getComputedStyle(document.documentElement).overscrollBehaviorY,
                        contentOverscroll: getComputedStyle(content).overscrollBehaviorY};
                """, arguments: [:], in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result, let report = value as? [String: Any] else {
                    fatalError("Scroll appearance check failed: \(result)")
                }
                assert(report["supported"] as? Bool == true, "Run the scroll-driven appearance check on current WebKit")
                assert(report["rootOverscroll"] as? String == "none")
                assert(report["contentOverscroll"] as? String == "none", "Do not expose a black gap when reaching the edge")
                for edge in report["overlayEdges"] as! [Double] {
                    assert(abs(edge - (report["contentRight"] as! Double)) < 0.5,
                           "Header layers must leave the scrollbar visible and clickable")
                }
                for sample in report["samples"] as! [[String: Double]] {
                    let expected = min(1, sample["top"]! / 96)
                    assert(abs(sample["header"]! - expected) < 0.02,
                           "Reveal the gradient before reaching the top, in both scroll directions: \(sample)")
                    assert(abs(sample["guide"]! - expected) < 0.02, "Keep the compact sidebar in sync with the header")
                }
                timer.invalidate()
                print("PASS: layout, hit testing, gutter-free overlay, two-way scrolling, resize/replacement, gradient reveal, and overscroll containment")
                exit(0)
            }
            return
        }
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
                stage = 3
                checking = false
                web.loadHTMLString("""
                    <!doctype html><html><style>
                    html, body { margin:0; background:black; overflow:hidden }
                    ytmusic-app-layout { display:block }
                    #content { height:100vh; overflow-y:scroll }
                    #nav-bar-background, #mini-guide-background {
                        position:fixed; top:0; left:0; height:64px; width:100%;
                        background:black; opacity:1; transition:opacity 0.2s;
                    }
                    #mini-guide-background { width:72px; height:100vh }
                    #nav-bar-divider { position:fixed; top:64px; left:0; width:100%; height:1px }
                    ytmusic-nav-bar { display:block; position:fixed; top:0; left:0; width:100%; height:64px }
                    </style><body><ytmusic-app-layout>
                    <div id="nav-bar-background"></div><div id="nav-bar-divider"></div>
                    <ytmusic-nav-bar></ytmusic-nav-bar><div id="mini-guide-background"></div>
                    <main id="content"><div style="height:300vh;background:linear-gradient(red,blue)">Scroll check</div></main>
                    </ytmusic-app-layout></body></html>
                    """, baseURL: URL(string: "https://music.youtube.com/"))
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
    # Failed assertions must not leave a restore-windows dialog blocking the next run.
    subprocess.run([str(binary), "-ApplePersistenceIgnoreState", "YES", *sys.argv[1:]], check=True, timeout=20)
