import AppKit
import WebKit

final class MusicApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var updates: MusicUpdates!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // macOS prefers interval skipping when YouTube registers both kinds of controls.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'music.youtube.com' && navigator.mediaSession) {
            const setActionHandler = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
            let update;
            const preferTrackControls = () => {
                clearTimeout(update);
                update = setTimeout(() => {
                    setActionHandler('seekbackward', null);
                    setActionHandler('seekforward', null);
                }, 0);
            };
            navigator.mediaSession.setActionHandler = (action, handler) => {
                setActionHandler(action, handler);
                if (action === 'seekbackward' || action === 'seekforward') preferTrackControls();
            };
            document.addEventListener('playing', preferTrackControls, true);
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        let safariVersion = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "18.0"
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Music"
        window.center()
        window.contentView = webView
        window.delegate = self
        updates = MusicUpdates()
        updates.attach(to: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
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

let app = NSApplication.shared
let delegate = MusicApp()
app.delegate = delegate
app.setActivationPolicy(.regular)

let menu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Music", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appItem = NSMenuItem()
appItem.submenu = appMenu
menu.addItem(appItem)

let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
fileItem.submenu = fileMenu
menu.addItem(fileItem)

app.mainMenu = menu
app.run()
