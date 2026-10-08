import AppKit
import Sparkle

final class MusicUpdates: NSObject, NSMenuDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, SUVersionDisplay {
    let menu = NSMenu(title: "Updates")
    private let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private weak var window: NSWindow?
    private var controller: SPUStandardUpdaterController!
    private var availableUpdate: SUAppcastItem?
    private var availabilityObservation: NSKeyValueObservation?
    private var releaseNotesTask: Task<Void, Never>?
    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        menu.autoenablesItems = false
        menu.delegate = self
        checkItem.toolTip = "Not checked yet"
        let notesItem = NSMenuItem(title: "What’s New…", action: #selector(showReleaseNotes), keyEquivalent: "")
        for item in [checkItem, notesItem] {
            item.target = self
            menu.addItem(item)
        }
        availabilityObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            self?.refreshMenu()
        }
    }

    func attach(to window: NSWindow) {
        self.window = window
        let updatesItem = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        updatesItem.submenu = menu
        NSApp.mainMenu?.addItem(updatesItem)
        do {
            try updater.start()
        } catch {
            checkItem.toolTip = "Updates unavailable: \(error.localizedDescription)"
        }
    }

    @objc private func showReleaseNotes() {
        guard let window else { return }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        guard window.attachedSheet == nil else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let alert = NSAlert()
        alert.messageText = "Music \(version)"
        alert.informativeText = "What’s New in This Version"
        alert.addButton(withTitle: "Done")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("What’s New in This Version")
        textView.string = "Loading release notes…"
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.releaseNotesTask?.cancel()
            self?.releaseNotesTask = nil
        }
        releaseNotesTask = Task { @MainActor in
            let notes = await MusicReleaseNotes.load(version: version)
            guard !Task.isCancelled else { return }
            textView.string = notes.cached ? "Couldn’t refresh — showing saved release notes.\n\n\(notes.text)" : notes.text
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    @objc func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

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
