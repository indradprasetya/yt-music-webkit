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
        assert(web.frame == background.bounds, "One web view fills the page and title bar")
        let hit = background.hitTest(NSPoint(x: background.bounds.midX, y: background.bounds.midY))!
        assert(hit === web || hit.isDescendant(of: web), "Page controls remain interactive")
        let titlebarHit = background.hitTest(NSPoint(x: background.bounds.midX, y: background.bounds.maxY - 2))
        assert(titlebarHit === background, "Reserve the title bar for native window dragging")
    }
    background.extendsUnderTitlebar = false
    background.layoutSubtreeIfNeeded()
    assert(web.frame == background.convert(window.contentLayoutRect, from: nil), "Keep external sign-in pages below the title bar")
    background.extendsUnderTitlebar = true
    background.layoutSubtreeIfNeeded()
    if CommandLine.arguments.contains("--layout-only") {
        print("PASS: full-window background, native dragging, resizing, and external-page insets")
        exit(0)
    }
    web.loadHTMLString("""
        <!doctype html><html><style>
        :root { --ytmusic-nav-bar-height:64px }
        html, body { margin:0; background:black }
        ytmusic-app-layout { display:block }
        #content { height:100vh; overflow-y:scroll; position:relative }
        #photo { position:absolute; top:0; width:100%; height:360px; object-fit:cover }
        #nav-bar-background, #mini-guide-background {
            position:fixed; top:0; left:0; height:var(--ytmusic-nav-bar-height); width:100%;
            background:black; opacity:1; transition:opacity 0.2s; z-index:5;
        }
        #mini-guide-background { width:72px; height:100vh }
        #nav-bar-divider { position:fixed; top:var(--ytmusic-nav-bar-height); width:100%; height:1px }
        ytmusic-nav-bar { display:block; position:fixed; top:0; left:0; width:100%; height:var(--ytmusic-nav-bar-height); z-index:5 }
        </style><body><ytmusic-app-layout is-contained-content-layout-enabled>
        <div id="nav-bar-background"></div><div id="nav-bar-divider"></div>
        <ytmusic-nav-bar>Search</ytmusic-nav-bar><div id="mini-guide-background"></div>
        <main id="content"><div style="height:300vh;background:linear-gradient(red,blue)">
        <img id="photo" alt="" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 600 360'%3E%3Cpath fill='red' d='M0 0h600v120H0z'/%3E%3Cpath fill='blue' d='M0 120h600v240H0z'/%3E%3C/svg%3E">
        </div></main></ytmusic-app-layout></body></html>
        """, baseURL: URL(string: "https://music.youtube.com/"))
    let deadline = Date().addingTimeInterval(15)
    var checking = false
    _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
        if Date() > deadline { fatalError("Window layout did not settle") }
        guard !web.isLoading, !checking else { return }
        checking = true
        web.callAsyncJavaScript("""
                const content = document.querySelector('ytmusic-app-layout > #content');
                const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--music-titlebar-height'));
                const header = document.querySelector('#nav-bar-background');
                const guide = document.querySelector('#mini-guide-background');
                const bar = document.querySelector('#music-scrollbar');
                const settle = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                const check = (condition, message) => { if (!condition) throw new Error(message); };
                check(!!bar, 'Create the overlay scrollbar');
                if (!CSS.supports('animation-timeline: --music-titlebar-scroll')) return {supported: false};
                const nav = document.querySelector('ytmusic-nav-bar').getBoundingClientRect();
                check(nav.top === inset && nav.height === 64, 'Keep the search/header below the window buttons at its original height');
                const photo = document.querySelector('#photo').getBoundingClientRect();
                check(photo.top === 0 && photo.height === 360, 'Render the original picture from the top, without stretching a row');
                check(header.getBoundingClientRect().height === inset + 64, 'The scrolled header also covers the title bar');
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
                check(bounds.top === inset + 8 && bounds.right === innerWidth - 4,
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
                document.querySelector('ytmusic-app-layout').removeAttribute('is-contained-content-layout-enabled');
                content.style.height = 'auto';
                content.style.overflow = 'visible';
                await settle();
                document.scrollingElement.scrollTop = 160;
                await settle();
                check(bar.scrollTop === 160, 'Follow document scrolling in the other YouTube layout');
                bar.scrollTop = 240;
                await settle();
                check(document.scrollingElement.scrollTop === 240, 'The thumb controls document scrolling too');
                check(bar.getBoundingClientRect().top === inset + 8, 'Root scrolling keeps the thumb out of the title bar');
                return {supported: true, samples,
                        rootOverscroll: getComputedStyle(document.documentElement).overscrollBehaviorY,
                        contentOverscroll: getComputedStyle(content).overscrollBehaviorY};
            """, arguments: [:], in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, let report = value as? [String: Any] else {
                fatalError("Scroll appearance check failed: \(result)")
            }
            assert(report["supported"] as? Bool == true, "Run the scroll-driven appearance check on current WebKit")
            assert(report["rootOverscroll"] as? String == "none")
            assert(report["contentOverscroll"] as? String == "none")
            for sample in report["samples"] as! [[String: Double]] {
                let expected = min(1, sample["top"]! / 96)
                assert(abs(sample["header"]! - expected) < 0.02, "Fade follows scrolling in both directions: \(sample)")
                assert(abs(sample["guide"]! - expected) < 0.02, "Keep the compact sidebar in sync")
            }
            timer.invalidate()
            print("PASS: full-window photo, header insets, native dragging, nested/root scrolling, resize/replacement, and gradient reveal")
            exit(0)
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
    source = source.replace('startupMessages.start(version: version)', '')
    script = work / "main.swift"
    script.write_text(source.replace("NSApp.activate(ignoringOtherApps: true)",
                                     "NSApp.activate(ignoringOtherApps: true)\n" + checks, 1))
    binary = app / "MacOS/WindowCheck"
    subprocess.run(["xcrun", "swiftc", "-F", str(frameworks), "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", str(frameworks), str(script),
                    str(root / "Music/MusicUpdates.swift"), str(root / "Music/MusicReleaseNotes.swift"),
                    str(root / "Music/MusicStartupRules.swift"), str(root / "Music/MusicStartupMessages.swift"),
                    "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    # Failed assertions must not leave a restore-windows dialog blocking the next run.
    subprocess.run([str(binary), "-ApplePersistenceIgnoreState", "YES", *sys.argv[1:]], check=True, timeout=20)
