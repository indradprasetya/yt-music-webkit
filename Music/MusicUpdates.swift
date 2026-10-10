import AppKit
import Sparkle
import WebKit

final class MusicUpdates: NSObject, NSMenuItemValidation, NSWindowDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, SUVersionDisplay, WKNavigationDelegate {
    private let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private var releaseNotesWindow: NSPanel?
    private var controller: SPUStandardUpdaterController!
    private var availableUpdate: SUAppcastItem?
    private var availabilityObservation: NSKeyValueObservation?
    private var releaseNotesTask: Task<Void, Never>?
    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        checkItem.toolTip = "Not checked yet"
        checkItem.target = self
        availabilityObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            self?.refreshMenu()
        }
    }

    func attach(to appMenu: NSMenu, helpMenu: NSMenu) {
        appMenu.insertItem(checkItem, at: 2)
        appMenu.insertItem(.separator(), at: 3)
        helpMenu.addItem(withTitle: "What’s New…", action: #selector(showReleaseNotes), keyEquivalent: "").target = self
        do {
            try updater.start()
        } catch {
            checkItem.toolTip = "Updates unavailable: \(error.localizedDescription)"
        }
    }

    @objc func showReleaseNotes() {
        if let releaseNotesWindow {
            releaseNotesWindow.makeKeyAndOrderFront(nil)
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Music \(version)"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let notesView = WKWebView(frame: NSRect(x: 20, y: 20, width: 440, height: 200), configuration: configuration)
        // macOS WebKit otherwise paints an opaque page even with transparent HTML.
        notesView.setValue(false, forKey: "drawsBackground")
        notesView.navigationDelegate = self
        notesView.loadHTMLString(MusicReleaseNotes.document(html: "<p role=\"status\">Loading release notes…</p>"), baseURL: nil)
        panel.contentView?.addSubview(notesView)
        releaseNotesWindow = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        releaseNotesTask = Task { @MainActor in
            let notes = await MusicReleaseNotes.load(version: version)
            guard !Task.isCancelled else { return }
            notesView.loadHTMLString(MusicReleaseNotes.document(html: notes.html, cached: notes.cached), baseURL: nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === releaseNotesWindow else { return }
        releaseNotesTask?.cancel()
        releaseNotesTask = nil
        releaseNotesWindow = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .linkActivated,
           let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(navigationAction.navigationType == .other && url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    @objc func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem !== checkItem || updater.canCheckForUpdates
    }

    private func refreshMenu() {
        checkItem.isEnabled = updater.canCheckForUpdates
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: address) else { return nil }
        #if arch(arm64)
        let filename = "appcast-arm64.xml"
        #else
        let filename = "appcast-x86_64.xml"
        #endif
        return url.deletingLastPathComponent().appendingPathComponent(filename).absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        checkItem.toolTip = "Checking…"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = item
        checkItem.toolTip = "Update available"
        checkItem.title = "Update to \(item.displayVersionString)…"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableUpdate = nil
        checkItem.title = "Check for Updates…"
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int
        let current = [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion].contains { Int($0.rawValue) == reason }
        checkItem.toolTip = current ? "Up to date" : "No compatible update available"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError?,
           !(error.domain == SUSparkleErrorDomain && [SUError.noUpdateError, .installationCanceledError].contains { Int($0.rawValue) == error.code }) {
            let message = availableUpdate == nil ? "Couldn’t check for updates" : "Update couldn’t complete"
            checkItem.toolTip = "\(message): \(error.localizedDescription)"
        }
        refreshMenu()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverRequestsVersionDisplayer() -> SUVersionDisplay? { self }

    func formatUpdateVersion(fromUpdate update: SUAppcastItem, andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>, withBundleVersion bundleVersion: String) -> String {
        update.displayVersionString
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updater(updater, didFindValidUpdate: update)
    }
}
