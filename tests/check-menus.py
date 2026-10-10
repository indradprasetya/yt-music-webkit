#!/usr/bin/env python3
"""Exercise the real AppKit menus and WebKit bridge with an offline player fixture."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
frameworks = Path(os.environ.get('MUSIC_TEST_FRAMEWORKS', root / 'dist/updater-build/Build/Products/Debug'))
assert (frameworks / 'Sparkle.framework').exists(), 'Build Debug in dist/updater-build first'
checks = r'''
Task { @MainActor in
    setbuf(stdout, nil)
    @MainActor func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try! await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("Timed out waiting for menu/player state")
    }
    @MainActor func js(_ script: String) async -> Any? {
        do { return try await webView.evaluateJavaScript(script) }
        catch { fatalError("JavaScript failed: \(error) in \(script)") }
    }
    let menu = NSApp.mainMenu as! MusicMenu
    assert(menu.items.map(\.title) == ["Music", "File", "Edit", "View", "Controls", "Window", "Help"])
    let appMenu = menu.items[0].submenu!
    let file = menu.items[1].submenu!
    let view = menu.items[3].submenu!
    let windows = menu.items[5].submenu!
    let help = menu.items[6].submenu!
    assert(appMenu.items[2].title == "Check for Updates…")
    assert(appMenu.items.contains { $0.submenu === NSApp.servicesMenu })
    assert(NSApp.windowsMenu === windows && NSApp.helpMenu === help)
    assert(help.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Report an Issue…", "What’s New…"])
    assert(help.items[0].target === self && help.items[0].action == #selector(reportIssue))
    assert(!validateMenuItem(file.items[0]), "No URL yet")
    let play = playbackMenu.items.first { $0.representedObject as? String == "playpause" }!
    let next = playbackMenu.items.first { $0.representedObject as? String == "nexttrack" }!
    let mute = playbackMenu.items.first { $0.representedObject as? String == "mute" }!
    assert(!validateMenuItem(play), "Disable playback before the player is ready")
    webView.loadHTMLString("<html><body><div id='movie_player'></div><video></video><input id='search'><div id='editor' contenteditable='true'></div></body></html>",
                          baseURL: URL(string: "https://music.youtube.com/"))
    await waitFor { !webView.isLoading && webView.url?.host == "music.youtube.com" }
    _ = await js("""
        window.testPaused = true;
        window.calls = [];
        const video = document.querySelector('video');
        const player = document.querySelector('#movie_player');
        let volume = 100;
        player.getVolume = () => volume;
        player.setVolume = value => { volume = value; video.volume = value / 100; };
        player.isMuted = () => video.muted;
        player.mute = () => { video.muted = true; };
        player.unMute = () => { video.muted = false; };
        Object.defineProperty(video, 'readyState', {get: () => 1});
        Object.defineProperty(video, 'paused', {get: () => window.testPaused});
        for (const action of ['play', 'pause', 'nexttrack', 'previoustrack']) {
            navigator.mediaSession.setActionHandler(action, details => {
                calls.push(details.action);
                if (action === 'play' || action === 'pause') {
                    window.testPaused = action === 'pause';
                    video.dispatchEvent(new Event(action));
                }
            });
        }
        window.musicPlayback.update(true);
        """)
    await waitFor { self.playbackState["playpause"] == true }
    assert(validateMenuItem(file.items[0]))
    assert(validateMenuItem(play) && play.title == "Play")
    assert(validateMenuItem(next))
    assert(NSApp.sendAction(play.action!, to: play.target, from: play))
    await waitFor { self.playbackState["paused"] == false }
    assert(play.title == "Pause", "Update the label without opening the menu")
    assert(NSApp.sendAction(next.action!, to: next.target, from: next))
    _ = await js("document.querySelector('#movie_player').setVolume(50)")
    assert(NSApp.sendAction(mute.action!, to: mute.target, from: mute))
    await waitFor { self.playbackState["muted"] == true }
    assert(mute.title == "Unmute")
    let volume = await js("document.querySelector('video').volume") as! Double
    assert(volume == 0.5)
    let calls = await js("window.calls") as! [String]
    assert(calls == ["play", "nexttrack"], "Native menus must dispatch the registered website callbacks")

    @MainActor func key(_ value: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: value,
                        charactersIgnoringModifiers: value, isARepeat: false, keyCode: 49)!
    }
    _ = await js("document.getElementById('search').focus()")
    await waitFor { menu.editing }
    assert(!menu.performKeyEquivalent(with: key(" ")), "Space must reach the text field")
    assert(!menu.performKeyEquivalent(with: key("\u{F702}", .command)), "Command-arrow must reach the text field")
    _ = await js("document.getElementById('editor').focus()")
    await waitFor { menu.editing }
    assert(!menu.performKeyEquivalent(with: key(" ")), "Protect contenteditable too")
    _ = await js("document.activeElement.blur()")
    await waitFor { !menu.editing }
    await waitFor { NSApp.keyWindow === window }
    assert(menu.performKeyEquivalent(with: key(" ")), "Space controls playback outside text fields")
    await waitFor { self.playbackState["paused"] == true }

    assert(NSApp.sendAction(file.items[1].action!, to: nil, from: file.items[1]))
    assert(!window.isVisible && playbackState["playpause"] == true, "Closing Music must preserve its player")
    let show = windows.items.first { $0.title == "Show Music" }!
    assert(NSApp.sendAction(show.action!, to: show.target, from: show))
    await waitFor { window.isVisible && NSApp.keyWindow === window }
    window.performMiniaturize(nil)
    assert(NSApp.sendAction(show.action!, to: show.target, from: show))
    await waitFor { !window.isMiniaturized && window.isVisible }
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.makeKeyAndOrderFront(nil)
    await waitFor { NSApp.keyWindow === panel }
    let panelKey = key(" ")
    assert(!menu.performKeyEquivalent(with: panelKey), "Do not take playback shortcuts from another window")
    assert(NSApp.sendAction(file.items[1].action!, to: nil, from: file.items[1]))
    assert(!panel.isVisible && window.isVisible, "Close acts on the active panel")
    showMusic()
    let fullScreen = view.items.last!
    assert(fullScreen.action == #selector(NSWindow.toggleFullScreen(_:)))
    assert(fullScreen.keyEquivalent == "f" && fullScreen.keyEquivalentModifierMask == [.command, .control])
    window.toggleFullScreen(nil)
    await waitFor { window.styleMask.contains(.fullScreen) }
    view.update()
    assert(fullScreen.title == "Exit Full Screen")
    try! await Task.sleep(nanoseconds: 1_000_000_000)
    window.toggleFullScreen(nil)
    await waitFor { !window.styleMask.contains(.fullScreen) }
    view.update()
    assert(fullScreen.title == "Enter Full Screen")

    _ = await js("""
        const frame = document.createElement('iframe');
        frame.srcdoc = '<script>webkit.messageHandlers.playbackState.postMessage({playpause:false,editing:true})<\\/script>';
        document.body.append(frame);
        webkit.messageHandlers.playbackState.postMessage({playpause:'invalid'}); null;
        """)
    try! await Task.sleep(nanoseconds: 100_000_000)
    assert(playbackState["playpause"] == true && !menu.editing, "Ignore subframe and malformed messages")
    webView.loadHTMLString("<html><body>Sign in</body></html>", baseURL: URL(string: "https://accounts.google.com/"))
    await waitFor { !webView.isLoading && webView.url?.host == "accounts.google.com" }
    assert(!validateMenuItem(file.items[0]), "Do not export login URLs")
    assert(!validateMenuItem(play) && menu.editing, "Navigation resets playback")
    _ = await js("webkit.messageHandlers.playbackState.postMessage({playpause:true,editing:false}); null")
    try! await Task.sleep(nanoseconds: 100_000_000)
    assert(!validateMenuItem(play) && menu.editing, "Ignore messages from the login origin")
    print("PASS: native menus, WebKit dispatch, focus-safe shortcuts, window actions, full screen, and origin validation")
    exit(0)
}
'''
with tempfile.TemporaryDirectory(prefix='music-menu-check-') as directory:
    work = Path(directory)
    app = work / 'MenuCheck.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    info = plistlib.loads((root / 'Music/Info.plist').read_bytes())
    info.update(CFBundleIdentifier='com.dyan.music-menu-check', CFBundleExecutable='MenuCheck',
                CFBundleName='Music', CFBundleVersion='1', CFBundleShortVersionString='1.1.1',
                SUEnableAutomaticChecks=False)
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    source = (root / 'Music/main.swift').read_text()
    source = source.replace('webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))', '')
    script = work / 'main.swift'
    script.write_text(source.replace('NSApp.activate(ignoringOtherApps: true)',
                                    'NSApp.activate(ignoringOtherApps: true)\n' + checks, 1))
    binary = app / 'MacOS/MenuCheck'
    subprocess.run(['xcrun', 'swiftc', '-F', str(frameworks), '-framework', 'Sparkle',
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks), str(script),
                    str(root / 'Music/MusicUpdates.swift'), str(root / 'Music/MusicReleaseNotes.swift'),
                    '-o', str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'))
    subprocess.run([str(binary)], check=True, timeout=30)
