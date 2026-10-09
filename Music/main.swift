import AppKit
import WebKit

final class MusicApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var updates: MusicUpdates!
    private var backgroundObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Never advertise interval skipping: Now Playing can cache those initial controls.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com' && navigator.mediaSession) {
            // Keep the hook on the prototype, even if WebKit recreates the session wrapper.
            const setActionHandler = MediaSession.prototype.setActionHandler;
            MediaSession.prototype.setActionHandler = function(action, handler) {
                setActionHandler.call(this, action, action === 'seekbackward' || action === 'seekforward' ? null : handler);
            };
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, contentWorld: .defaultClient, name: "titlebarContentWidth")
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com') {
            let scheduled = false;
            let previousWidth = '';
            const resizeObserver = new ResizeObserver(update);
            const observed = new Set();
            function update() {
                if (scheduled) return;
                scheduled = true;
                requestAnimationFrame(() => {
                    scheduled = false;
                    let contentWidth = document.documentElement.clientWidth;
                    const elements = document.elementsFromPoint(innerWidth - 1, 0);
                    for (const element of observed) {
                        if (!elements.includes(element)) {
                            resizeObserver.unobserve(element);
                            observed.delete(element);
                        }
                    }
                    for (const element of elements) {
                        if (!observed.has(element)) {
                            observed.add(element);
                            resizeObserver.observe(element);
                        }
                        if (element.scrollHeight > element.clientHeight && element.offsetWidth > element.clientWidth) {
                            contentWidth = Math.min(contentWidth,
                                element.getBoundingClientRect().left + element.clientLeft + element.clientWidth);
                        }
                    }
                    const width = `${contentWidth}/${innerWidth}`;
                    if (width === previousWidth) return;
                    previousWidth = width;
                    document.documentElement.style.setProperty('--music-header-content-width', `${contentWidth}px`);
                    window.webkit.messageHandlers.titlebarContentWidth.postMessage({contentWidth, viewportWidth: innerWidth});
                });
            }
            new MutationObserver(update).observe(document.documentElement, {
                subtree: true, childList: true, attributes: true, attributeFilter: ['style', 'class', 'hidden']
            });
            window.addEventListener('resize', update, {passive: true});
            update();
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com') {
            const style = document.createElement('style');
            style.textContent = `
                /* Rubber-banding must not expose a black gap along the replicated edge. */
                html, body, ytmusic-app-layout > #content { overscroll-behavior-y: none !important; }
                /* Keep header paint and hit testing out of the scrollbar gutter. */
                ytmusic-app-layout > #nav-bar-background,
                ytmusic-app-layout > #nav-bar-divider,
                ytmusic-app-layout > ytmusic-nav-bar {
                    width: var(--music-header-content-width, 100%) !important;
                }
                /* shortcut: Older WebKit keeps YouTube's fade; add a fallback if it needs the gradual reveal. */
                @supports (animation-timeline: --music-titlebar-scroll) and (timeline-scope: --music-titlebar-scroll) {
                    ytmusic-app-layout { timeline-scope: --music-titlebar-scroll; }
                    ytmusic-app-layout > #content { scroll-timeline: --music-titlebar-scroll block; }
                    ytmusic-app-layout > #nav-bar-background,
                    ytmusic-app-layout > #mini-guide-background {
                        animation: music-titlebar-fade linear both;
                        animation-timeline: --music-titlebar-scroll;
                        animation-range: 0px 96px;
                        transition: none !important;
                    }
                    @keyframes music-titlebar-fade { from { opacity: 0; } to { opacity: 1; } }
                }
            `;
            document.documentElement.append(style);
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com') {
            const style = document.createElement('style');
            style.textContent = `
                ytmusic-app-layout > #content { scrollbar-width:none !important; }
                ytmusic-app-layout > #content::-webkit-scrollbar { display:none !important; }
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
            let content, scheduled = false, syncedTop = 0;
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
                    const next = document.querySelector('ytmusic-app-layout > #content');
                    if (next === content) syncFromBar();
                    if (next !== content) {
                        if (content) {
                            content.removeEventListener('scroll', schedule);
                        }
                        observer.disconnect();
                        observed.clear();
                        content = next;
                        if (content) {
                            content.addEventListener('scroll', schedule, {passive:true});
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
                    const rect = content.getBoundingClientRect();
                    const range = content.scrollHeight - content.clientHeight;
                    bar.hidden = range <= 0 || rect.height <= 16 || getComputedStyle(content).visibility === 'hidden';
                    const top = Math.max(0, rect.top) + 8;
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
                subtree:true, childList:true, attributes:true, attributeFilter:['style', 'class', 'hidden']
            });
            window.addEventListener('resize', schedule, {passive:true});
            document.addEventListener('load', schedule, true);
            schedule();
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        let safariVersion = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.0"
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Music"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        backgroundObservation = webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak window] view, _ in
            window?.backgroundColor = view.underPageBackgroundColor
        }
        window.center()
        window.contentView = TitlebarBackgroundView(webView: webView)
        window.delegate = self
        updates = MusicUpdates()
        updates.attach(to: window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "titlebarContentWidth", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "music.youtube.com",
              let widths = message.body as? [String: Double],
              let contentWidth = widths["contentWidth"], let viewportWidth = widths["viewportWidth"],
              contentWidth.isFinite, viewportWidth.isFinite,
              contentWidth > 0, contentWidth <= viewportWidth,
              let background = window.contentView as? TitlebarBackgroundView else { return }
        background.contentWidthFraction = CGFloat(contentWidth / viewportWidth)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func refresh() {
        webView.reload()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
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

final class TitlebarBackgroundView: NSView {
    let webView: WKWebView
    var contentWidthFraction: CGFloat = 1 { didSet { needsLayout = true } }
    private let verticalExtension = NSView()
    private let contentMask = CAShapeLayer()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        verticalExtension.layer = CAReplicatorLayer()
        verticalExtension.wantsLayer = true
        verticalExtension.layer?.mask = contentMask
        addSubview(verticalExtension)
        verticalExtension.addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { CAReplicatorLayer() }

    override func layout() {
        super.layout()
        guard let window, let horizontal = layer as? CAReplicatorLayer,
              let vertical = verticalExtension.layer as? CAReplicatorLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        verticalExtension.frame = bounds
        webView.frame = convert(window.contentLayoutRect, from: nil)
        let top = webView.frame.maxY
        let titlebarHeight = max(0, bounds.maxY - top)
        let contentWidth = max(1, bounds.width * contentWidthFraction)
        let gutterWidth = bounds.width - contentWidth

        // Replicate the live edge in the compositor, below the original page, with no snapshot delay.
        vertical.instanceCount = titlebarHeight > 0 ? 2 : 1
        var transform = CATransform3DMakeScale(1, titlebarHeight, 1)
        // Use the second point below the edge to skip YouTube Music's 1-point top border.
        transform.m42 = top - titlebarHeight * (top - 2)
        transform.m43 = -1
        vertical.instanceTransform = transform
        let path = CGMutablePath()
        path.addRect(webView.frame)
        path.addRect(CGRect(x: bounds.minX, y: top, width: contentWidth, height: titlebarHeight))
        contentMask.path = path

        // Extend the last content pixel across the gutter without copying the scrollbar above the page.
        horizontal.instanceCount = gutterWidth > 0 && titlebarHeight > 0 ? 2 : 1
        var edgeTransform = CATransform3DMakeScale(max(1, gutterWidth), 1, 1)
        edgeTransform.m41 = contentWidth - max(1, gutterWidth) * (contentWidth - 1)
        edgeTransform.m43 = -1
        horizontal.instanceTransform = edgeTransform
        horizontal.masksToBounds = true
        CATransaction.commit()
    }
}

let app = NSApplication.shared
let delegate = MusicApp()
app.delegate = delegate
app.setActivationPolicy(.regular)

let menu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Music", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
let refreshItem = appMenu.addItem(withTitle: "Refresh", action: #selector(MusicApp.refresh), keyEquivalent: "r")
refreshItem.target = delegate
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit Music", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appItem = NSMenuItem()
appItem.submenu = appMenu
menu.addItem(appItem)

app.mainMenu = menu
app.run()
