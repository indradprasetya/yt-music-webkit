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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 3 / 255, green: 3 / 255, blue: 3 / 255, alpha: 1)
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
