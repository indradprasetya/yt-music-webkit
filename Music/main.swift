import AppKit
import WebKit

final class MusicApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuItemValidation {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var updates: MusicUpdates!
    private var backgroundObservation: NSKeyValueObservation?
    private var playbackState: [String: Bool] = [:]
    private let playbackMenu = NSMenu(title: "Controls")
    private let repeatMenu = NSMenu(title: "Repeat")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Music"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let titlebarHeight = window.contentView!.bounds.height - window.contentLayoutRect.height
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "playbackState")
        // Never advertise interval skipping: Now Playing can cache those initial controls.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.protocol === 'https:' && location.hostname === 'music.youtube.com' && navigator.mediaSession) {
            const handlers = new Map();
            let lastState = '';
            let changingQueue = false;
            const repeatModes = {repeatoff: 'NONE', repeatall: 'ALL', repeatone: 'ONE'};
            const media = () => {
                const elements = [...document.querySelectorAll('video, audio')];
                return elements.find(element => !element.paused && !element.ended) || elements[0];
            };
            function volumeControls() {
                // shortcut: YouTube owns this player element; revisit if its exposed API changes.
                const player = document.querySelector('#movie_player');
                return player && ['getVolume', 'setVolume', 'isMuted', 'mute', 'unMute'].every(method =>
                    typeof player[method] === 'function') && Number.isFinite(player.getVolume()) ? player : null;
            }
            // shortcut: These queue fields and button classes belong to YouTube; revisit if its player UI changes.
            function queueState() {
                const app = document.querySelector('ytmusic-app');
                try { return typeof app?.getState === 'function' ? app.getState()?.queue : null; }
                catch { return null; }
            }
            function queueButton(action) {
                const name = action === 'shuffle' ? 'Shuffle' : 'Repeat';
                return [...document.querySelectorAll(`ytmusic-wiz-player-controls .ytmusicPlayerControls${name}Button button, ytmusic-player-bar .${action}`)]
                    .find(button => !button.disabled && !button.closest('[hidden], [disabled], [aria-disabled="true"], [aria-hidden="true"]')
                        && button.getClientRects().length > 0);
            }
            function update(force = false) {
                const player = media();
                const ready = !!player && player.readyState > 0 && !player.error;
                const audio = volumeControls();
                const muted = audio ? audio.isMuted() : !!player?.muted;
                const queue = queueState();
                const repeat = ready && !changingQueue && Object.values(repeatModes).includes(queue?.repeatMode) && !!queueButton('repeat');
                let focused = document.activeElement;
                while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
                const state = {
                    paused: !player || player.paused || player.ended,
                    muted,
                    playpause: ready && handlers.has(player.paused || player.ended ? 'play' : 'pause'),
                    nexttrack: ready && handlers.has('nexttrack'),
                    previoustrack: ready && handlers.has('previoustrack'),
                    volumeup: ready && !!audio && (audio.getVolume() < 100 || muted),
                    volumedown: ready && !!audio && audio.getVolume() > 0,
                    mute: ready && !!audio,
                    shuffle: ready && !changingQueue && typeof queue?.shuffleEnabled === 'boolean' && !!queueButton('shuffle'),
                    shuffled: queue?.shuffleEnabled === true,
                    repeatoff: repeat,
                    repeatall: repeat,
                    repeatone: repeat,
                    repeatoffSelected: queue?.repeatMode === 'NONE',
                    repeatallSelected: queue?.repeatMode === 'ALL',
                    repeatoneSelected: queue?.repeatMode === 'ONE',
                    editing: !!focused && (focused.isContentEditable || focused.matches('input, textarea, select, iframe, [role="textbox"]'))
                };
                const serialized = JSON.stringify(state);
                if (!force && serialized === lastState) return;
                lastState = serialized;
                window.webkit.messageHandlers.playbackState.postMessage(state);
            }
            window.musicPlayback = {
                update,
                async run(action) {
                    const player = media();
                    if (!player || player.readyState === 0 || player.error) return false;
                    try {
                        if (action === 'shuffle' || Object.hasOwn(repeatModes, action)) {
                            if (changingQueue) return false;
                            changingQueue = true;
                            try {
                                update();
                                if (action === 'shuffle') {
                                    const before = queueState()?.shuffleEnabled;
                                    const button = queueButton('shuffle');
                                    if (typeof before !== 'boolean' || !button) return false;
                                    button.click();
                                    await new Promise(resolve => setTimeout(resolve, 0));
                                    return queueState()?.shuffleEnabled === !before;
                                }
                                // Follow YouTube's cycle, re-reading state and the button after each render.
                                for (let clicks = 0; clicks < 2; clicks++) {
                                    const before = queueState()?.repeatMode;
                                    const button = queueButton('repeat');
                                    if (!Object.values(repeatModes).includes(before) || !button) return false;
                                    if (before === repeatModes[action]) return true;
                                    button.click();
                                    await new Promise(resolve => setTimeout(resolve, 0));
                                    if (queueState()?.repeatMode === before) return false;
                                }
                                return queueState()?.repeatMode === repeatModes[action];
                            } finally {
                                changingQueue = false;
                            }
                        } else if (['volumeup', 'volumedown', 'mute'].includes(action)) {
                            const audio = volumeControls();
                            if (!audio) return false;
                            // Keep the website's slider, saved volume, and loudness normalization in sync.
                            if (action === 'mute') {
                                if (audio.isMuted()) audio.unMute();
                                else audio.mute();
                            } else {
                                audio.setVolume(Math.max(0, Math.min(100, audio.getVolume() + (action === 'volumeup' ? 5 : -5))));
                                if (action === 'volumeup' && audio.isMuted()) audio.unMute();
                            }
                        } else {
                            if (action === 'playpause') action = player.paused || player.ended ? 'play' : 'pause';
                            if (!['play', 'pause', 'nexttrack', 'previoustrack'].includes(action) || !handlers.has(action)) return false;
                            await handlers.get(action)({action});
                        }
                        return true;
                    } finally {
                        update();
                    }
                }
            };
            // Keep the hook on the prototype, even if WebKit recreates the session wrapper.
            const setActionHandler = MediaSession.prototype.setActionHandler;
            MediaSession.prototype.setActionHandler = function(action, handler) {
                setActionHandler.call(this, action, action === 'seekbackward' || action === 'seekforward' ? null : handler);
                if (handler) handlers.set(action, handler);
                else handlers.delete(action);
                update();
            };
            for (const event of ['DOMContentLoaded', 'loadedmetadata', 'loadstart', 'emptied', 'play', 'pause', 'ended', 'volumechange', 'error', 'focusin', 'focusout']) {
                document.addEventListener(event, () => queueMicrotask(update), true);
            }
            // Follow website toggles and replacement controls without polling.
            const controls = '#movie_player, ytmusic-wiz-player-controls, ytmusic-player-bar';
            new MutationObserver(records => {
                if (records.some(({target, addedNodes, removedNodes}) => target.closest?.(controls)
                    || [...addedNodes, ...removedNodes].some(node => node.matches?.(controls) || node.querySelector?.(controls)))) update();
            }).observe(document, {subtree: true, childList: true, attributes: true,
                attributeFilter: ['aria-pressed', 'aria-label', 'aria-disabled', 'disabled', 'hidden']});
            update();
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, contentWorld: .defaultClient, name: "titlebarReady")
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com') {
            const style = document.createElement('style');
            style.textContent = `
                :root {
                    --music-titlebar-height: \(titlebarHeight)px;
                    --music-nav-bar-height: var(--ytmusic-nav-bar-height, 64px);
                }
                /* Keep controls below the window buttons; the original background starts at y=0. */
                ytmusic-app-layout {
                    --ytmusic-nav-bar-height: calc(var(--music-nav-bar-height) + var(--music-titlebar-height));
                }
                ytmusic-app-layout > ytmusic-nav-bar {
                    top: var(--music-titlebar-height) !important;
                    --ytmusic-nav-bar-height: var(--music-nav-bar-height);
                }
                .guide-nav.ytmusic-guide-renderer { padding-top: var(--music-titlebar-height) !important; }
                ytmusic-app-layout[is-mweb-modernization-enabled]:not([player-fullscreened]) > #player-page {
                    top: var(--music-titlebar-height) !important;
                    height: calc(100% - var(--music-titlebar-height)) !important;
                }
                html, body, ytmusic-app-layout > #content { overscroll-behavior-y: none !important; }
                /* shortcut: Older WebKit keeps YouTube's fade; add a fallback if it needs the gradual reveal. */
                @supports (animation-timeline: --music-titlebar-scroll) and (timeline-scope: --music-titlebar-scroll) {
                    html { scroll-timeline: --music-root-scroll block; }
                    ytmusic-app-layout { timeline-scope: --music-titlebar-scroll; }
                    ytmusic-app-layout > #content { scroll-timeline: --music-titlebar-scroll block; }
                    ytmusic-app-layout > #nav-bar-background,
                    ytmusic-app-layout > #mini-guide-background {
                        animation: music-titlebar-fade linear both;
                        animation-timeline: --music-titlebar-scroll;
                        animation-range: 0px 96px;
                        transition: none !important;
                    }
                    ytmusic-app-layout:not([is-contained-content-layout-enabled]) > #nav-bar-background,
                    ytmusic-app-layout:not([is-contained-content-layout-enabled]) > #mini-guide-background {
                        animation-timeline: --music-root-scroll;
                    }
                    @keyframes music-titlebar-fade { from { opacity: 0; } to { opacity: 1; } }
                }
            `;
            document.documentElement.append(style);
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com') {
            const style = document.createElement('style');
            style.textContent = `
                html, ytmusic-app-layout > #content { scrollbar-width:none !important; }
                html::-webkit-scrollbar, ytmusic-app-layout > #content::-webkit-scrollbar { display:none !important; }
                #music-scrollbar {
                    position:fixed; z-index:6; width:14px; overflow-x:hidden; overflow-y:scroll;
                    background:transparent; scrollbar-width:auto; overscroll-behavior:none;
                    opacity:1; outline:none;
                }
                #music-scrollbar:focus-visible { outline:2px solid #aaa; border-radius:9px; }
                #music-scrollbar::-webkit-scrollbar { width:14px; background:transparent; }
                #music-scrollbar::-webkit-scrollbar-track { background:transparent; }
                #music-scrollbar::-webkit-scrollbar-thumb {
                    min-height:32px; border:3px solid transparent; border-radius:10px;
                    background:rgba(255,255,255,.45); background-clip:padding-box;
                }
                #music-scrollbar::-webkit-scrollbar-thumb:hover { background-color:rgba(255,255,255,.65); }
                #music-scrollbar::-webkit-scrollbar-thumb:active { background-color:rgba(255,255,255,.8); }
                #music-scrollbar > div { width:1px; pointer-events:none; }
            `;
            document.documentElement.append(style);
            // Reuse WebKit's scrollbar for dragging, track clicks, and keyboard scrolling without reserving a gutter.
            const bar = document.createElement('div');
            bar.id = 'music-scrollbar';
            bar.tabIndex = 0;
            bar.setAttribute('role', 'region');
            bar.setAttribute('aria-label', 'Page scrollbar');
            const spacer = bar.appendChild(document.createElement('div'));
            document.body.append(bar);
            let content, scrollTarget, scheduled = false, syncedTop = 0;
            const observer = new ResizeObserver(schedule);
            const observed = new Set();
            function syncFromBar() {
                if (!content || bar.scrollTop === syncedTop) return;
                content.scrollTop = bar.scrollTop;
                syncedTop = bar.scrollTop;
            }
            bar.addEventListener('scroll', syncFromBar, {passive:true});
            function schedule() {
                if (scheduled) return;
                scheduled = true;
                requestAnimationFrame(() => {
                    scheduled = false;
                    const next = document.querySelector('ytmusic-app-layout[is-contained-content-layout-enabled] > #content')
                        || document.scrollingElement;
                    if (next === content) syncFromBar();
                    if (next !== content) {
                        if (content) {
                            scrollTarget.removeEventListener('scroll', schedule);
                        }
                        observer.disconnect();
                        observed.clear();
                        content = next;
                        if (content) {
                            scrollTarget = content === document.scrollingElement ? document : content;
                            scrollTarget.addEventListener('scroll', schedule, {passive:true});
                        }
                    }
                    if (!content) { bar.hidden = true; return; }
                    const elements = [content, ...content.children];
                    for (const element of observed) {
                        if (!elements.includes(element)) {
                            observer.unobserve(element);
                            observed.delete(element);
                        }
                    }
                    for (const element of elements) {
                        if (!observed.has(element)) {
                            observer.observe(element);
                            observed.add(element);
                        }
                    }
                    const rect = content === document.scrollingElement
                        ? {top:0, right:innerWidth, bottom:innerHeight, height:innerHeight}
                        : content.getBoundingClientRect();
                    const range = content.scrollHeight - content.clientHeight;
                    bar.hidden = range <= 0 || rect.height <= 16 || getComputedStyle(content).visibility === 'hidden';
                    const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--music-titlebar-height')) || 0;
                    const top = Math.max(inset, rect.top) + 8;
                    bar.style.top = `${top}px`;
                    bar.style.left = `${Math.min(innerWidth, rect.right) - 18}px`;
                    bar.style.height = `${Math.max(0, Math.min(innerHeight, rect.bottom) - top - 8)}px`;
                    spacer.style.height = `${range + bar.clientHeight}px`;
                    if (bar.scrollTop !== content.scrollTop) bar.scrollTop = content.scrollTop;
                    syncedTop = bar.scrollTop;
                });
            }
            new MutationObserver(records => {
                if (records.some(record => !bar.contains(record.target))) schedule();
            }).observe(document.documentElement, {
                subtree:true, childList:true, attributes:true, attributeFilter:['style', 'class', 'hidden', 'is-contained-content-layout-enabled']
            });
            window.addEventListener('resize', schedule, {passive:true});
            document.addEventListener('load', schedule, true);
            window.webkit.messageHandlers.titlebarReady.postMessage(null);
            schedule();
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        let safariVersion = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.0"
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))

        backgroundObservation = webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak window] view, _ in
            window?.backgroundColor = view.underPageBackgroundColor
        }
        window.center()
        window.contentView = TitlebarBackgroundView(webView: webView)
        window.delegate = self
        updates = MusicUpdates()
        makeMenu()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "playbackState" {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == "music.youtube.com",
                  musicURL != nil, let state = message.body as? [String: Bool] else { return }
            playbackState = state
            (NSApp.mainMenu as? MusicMenu)?.editing = state["editing"] ?? true
            playbackMenu.update()
            repeatMenu.update()
            return
        }
        guard message.name == "titlebarReady", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "music.youtube.com",
              musicURL != nil,
              let background = window.contentView as? TitlebarBackgroundView else { return }
        background.updatePageInsets()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func refresh() {
        webView.reload()
    }

    private var musicURL: URL? {
        guard let url = webView.url, url.scheme == "https", url.host == "music.youtube.com" else { return nil }
        return url
    }

    @objc private func openInBrowser() {
        guard let url = musicURL else { return }
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }

    @objc private func reportIssue() {
        if !NSWorkspace.shared.open(URL(string: "https://github.com/indradprasetya/yt-music-webkit/issues")!) {
            NSSound.beep()
        }
    }

    @objc private func showMusic() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func controlPlayback(_ sender: NSMenuItem) {
        guard musicURL != nil, let action = sender.representedObject as? String,
              playbackState[action] == true else { return }
        webView.callAsyncJavaScript("return await window.musicPlayback?.run(action) ?? false;",
                                   arguments: ["action": action], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value) where value as? Bool == true: break
            default:
                self?.resetPlayback()
                NSSound.beep()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openInBrowser): return musicURL != nil && !webView.isLoading
        case #selector(refresh): return true
        case #selector(controlPlayback(_:)):
            guard let action = menuItem.representedObject as? String else { return false }
            if action == "playpause" { menuItem.title = playbackState["paused"] == false ? "Pause" : "Play" }
            if action == "mute" { menuItem.title = playbackState["muted"] == true ? "Unmute" : "Mute" }
            if action == "shuffle" { menuItem.state = playbackState["shuffled"] == true ? .on : .off }
            if action.hasPrefix("repeat") { menuItem.state = playbackState[action + "Selected"] == true ? .on : .off }
            return musicURL != nil && playbackState[action] == true
        default: return true
        }
    }

    private func resetPlayback() {
        playbackState = [:]
        (NSApp.mainMenu as? MusicMenu)?.editing = true
        playbackMenu.update()
        repeatMenu.update()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { resetPlayback() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        resetPlayback()
        // Sign-in and other external pages retain the normal native content area.
        (window.contentView as? TitlebarBackgroundView)?.extendsUnderTitlebar = musicURL != nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { resetPlayback() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if musicURL != nil { webView.evaluateJavaScript("window.musicPlayback?.update(true)") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if musicURL != nil { webView.evaluateJavaScript("window.musicPlayback?.update(true)") }
    }

    private func makeMenu() {
        let menu = MusicMenu()
        menu.webView = webView
        let appMenu = NSMenu(title: "Music")
        appMenu.addItem(withTitle: "About Music", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Music", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Music", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "").target = self
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(refresh), keyEquivalent: "r").target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        for (title, action, key) in [("Play", "playpause", " "), ("Next Track", "nexttrack", "\u{F703}"),
                                     ("Previous Track", "previoustrack", "\u{F702}"), ("Volume Up", "volumeup", "\u{F700}"),
                                     ("Volume Down", "volumedown", "\u{F701}"), ("Mute", "mute", ""), ("Shuffle", "shuffle", "")] {
            if action == "nexttrack" || action == "volumeup" || action == "shuffle" { playbackMenu.addItem(.separator()) }
            let item = playbackMenu.addItem(withTitle: title, action: #selector(controlPlayback(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = action
            if action == "playpause" { item.keyEquivalentModifierMask = [] }
        }
        for (title, action) in [("Off", "repeatoff"), ("All", "repeatall"), ("One", "repeatone")] {
            let item = repeatMenu.addItem(withTitle: title, action: #selector(controlPlayback(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
        }
        playbackMenu.addItem(withTitle: "Repeat", action: nil, keyEquivalent: "").submenu = repeatMenu

        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Show Music", action: #selector(showMusic), keyEquivalent: "").target = self
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Report an Issue…", action: #selector(reportIssue), keyEquivalent: "").target = self
        help.addItem(.separator())
        for submenu in [appMenu, file, edit, view, playbackMenu, windows, help] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        NSApp.mainMenu = menu
        NSApp.servicesMenu = services
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
        updates.attach(to: appMenu, helpMenu: help)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMusic()
        return true
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

final class MusicMenu: NSMenu {
    weak var webView: WKWebView?
    var editing = true

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let playbackKey = (key == " " && modifiers.isEmpty)
            || (["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"].contains(key) && modifiers == .command)
        if playbackKey && (editing || NSApp.keyWindow !== webView?.window) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

final class TitlebarBackgroundView: NSView {
    let webView: WKWebView
    var extendsUnderTitlebar = true { didSet { needsLayout = true } }
    private var lastInset: CGFloat?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let window else { return }
        webView.frame = extendsUnderTitlebar ? bounds : convert(window.contentLayoutRect, from: nil)
        let inset = max(0, bounds.maxY - convert(window.contentLayoutRect, from: nil).maxY)
        if lastInset != inset {
            lastInset = inset
            updatePageInsets()
        }
    }

    func updatePageInsets() {
        guard let window else { return }
        let height = max(0, bounds.maxY - convert(window.contentLayoutRect, from: nil).maxY)
        webView.callAsyncJavaScript("""
            if (location.protocol === 'https:' && location.hostname === 'music.youtube.com' && document.documentElement) {
                document.documentElement.style.setProperty('--music-titlebar-height', `${height}px`);
            }
            """, arguments: ["height": height], in: nil, in: .defaultClient, completionHandler: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if let window, bounds.contains(localPoint), localPoint.y > convert(window.contentLayoutRect, from: nil).maxY {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

let app = NSApplication.shared
let delegate = MusicApp()
app.delegate = delegate
app.setActivationPolicy(.regular)

app.run()
