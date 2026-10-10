import AppKit
import WebKit

final class MusicStartupMessages: NSObject, WKNavigationDelegate {
    private weak var window: NSWindow?
    private let onUpdate: () -> Void
    private let onWhatsNew: () -> Void
    private var task: Task<Void, Never>?
    private var timeout: Timer?
    private var pageURL: URL?
    private var messageView: WKWebView?
    private var originalContent: NSView?
    private var originalBackground: NSColor?
    private var escapeMonitor: Any?

    init(window: NSWindow, onUpdate: @escaping () -> Void, onWhatsNew: @escaping () -> Void) {
        self.window = window
        self.onUpdate = onUpdate
        self.onWhatsNew = onWhatsNew
    }

    func start(version: String, manifestURL: URL = MusicStartupRules.manifestURL,
               defaults: UserDefaults = .standard) {
        task = Task { @MainActor [weak self] in
            let url = await MusicStartupRules.check(version: version, manifestURL: manifestURL, defaults: defaults)
            guard !Task.isCancelled, let self, let url,
                  let window = self.window, window.isVisible, !window.isMiniaturized else { return }
            self.load(url)
        }
    }

    private func load(_ url: URL) {
        pageURL = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: window?.contentLayoutRect ?? .zero, configuration: configuration)
        view.navigationDelegate = self
        messageView = view
        timeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.cancelPending()
        }
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5))
    }

    func cancelPending() {
        task?.cancel()
        task = nil
        timeout?.invalidate()
        timeout = nil
        guard originalContent == nil else { return }
        messageView?.stopLoading()
        messageView = nil
        pageURL = nil
    }

    func dismiss() {
        if let originalContent, let window {
            window.contentView = originalContent
            if let originalBackground { window.backgroundColor = originalBackground }
            window.makeFirstResponder(originalContent.subviews.first)
        }
        originalContent = nil
        originalBackground = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        cancelPending()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body?.innerText.trim().length > 0 && !!document.querySelector('a[href=\"music-action://continue\"]')") { [weak self, weak webView] result, _ in
            guard let self, let webView, webView === self.messageView else { return }
            guard result as? Bool == true else { self.cancelPending(); return }
            self.present(webView)
        }
    }

    private func present(_ webView: WKWebView) {
        guard webView === messageView, originalContent == nil,
              let window, window.isVisible, !window.isMiniaturized,
              let content = window.contentView,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide else {
            cancelPending()
            return
        }
        timeout?.invalidate()
        timeout = nil
        originalContent = content
        originalBackground = window.backgroundColor
        let container = NSView(frame: content.frame)
        window.contentView = container
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.backgroundColor = webView.underPageBackgroundColor
        window.makeFirstResponder(webView)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else { return event }
            self.dismiss()
            return nil
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === messageView, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let trustedSource = navigationAction.sourceFrame.isMainFrame
            && navigationAction.sourceFrame.request.url == pageURL
        if originalContent != nil, trustedSource, navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            switch url.absoluteString {
            case "music-action://continue": dismiss()
            case "music-action://update": onUpdate()
            case "music-action://whats-new": onWhatsNew()
            default:
                if url.scheme == "https" { NSWorkspace.shared.open(url) }
            }
            return
        }
        decisionHandler(originalContent == nil && navigationAction.targetFrame?.isMainFrame == true
                        && url == pageURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              response.statusCode == 200, response.url == pageURL,
              response.mimeType == "text/html" else {
            decisionHandler(.cancel)
            cancelPending()
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        cancelPending()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        cancelPending()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { dismiss() }

    deinit {
        task?.cancel()
        timeout?.invalidate()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
}
