import AppKit
import Sparkle

final class MusicUpdates: NSObject, NSMenuDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, SUVersionDisplay {
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
    let menu = NSMenu()
    private let statusItem = NSMenuItem(title: "Not checked yet", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Install Update…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let automaticItem = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
    private var controller: SPUStandardUpdaterController!
    private var availableUpdate: SUAppcastItem?
    private var availabilityObservation: NSKeyValueObservation?
    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        button.isBordered = false
        button.target = self
        button.action = #selector(showMenu)
        button.setAccessibilityLabel("Music information and updates")
        refreshButton()

        menu.autoenablesItems = false
        menu.delegate = self
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let versionItem = NSMenuItem(title: "Music \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        statusItem.isEnabled = false
        updateItem.isHidden = true
        for item in [versionItem, statusItem, updateItem, .separator(), checkItem, automaticItem] {
            item.target = self
            menu.addItem(item)
        }
        availabilityObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            self?.refreshMenu()
        }
    }

    func attach(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = button
        window.addTitlebarAccessoryViewController(accessory)

        let appMenuItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        appMenuItem.target = controller
        NSApp.mainMenu?.items.first?.submenu?.insertItem(appMenuItem, at: 0)
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            statusItem.title = "Updates unavailable"
            statusItem.toolTip = error.localizedDescription
        }
    }

    @objc private func showMenu() {
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX, y: button.bounds.minY), in: button)
    }

    @objc func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    @objc func toggleAutomaticChecks() {
        updater.automaticallyChecksForUpdates.toggle()
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        checkItem.isEnabled = updater.canCheckForUpdates
        updateItem.isEnabled = updater.canCheckForUpdates
        automaticItem.state = updater.automaticallyChecksForUpdates ? .on : .off
    }

    private func refreshButton() {
        button.image = NSImage(systemSymbolName: availableUpdate == nil ? "info.circle" : "info.circle.fill", accessibilityDescription: nil)
        button.contentTintColor = availableUpdate == nil ? .secondaryLabelColor : .controlAccentColor
        button.toolTip = availableUpdate == nil ? "Music information and updates" : "A Music update is available"
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
        statusItem.title = "Checking…"
        statusItem.toolTip = nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = item
        statusItem.title = "Update available"
        updateItem.title = "Update to \(item.displayVersionString)…"
        updateItem.isHidden = false
        refreshButton()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableUpdate = nil
        updateItem.isHidden = true
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int
        let current = [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion].contains { Int($0.rawValue) == reason }
        statusItem.title = current ? "Up to date" : "No compatible update available"
        refreshButton()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError?,
           !(error.domain == SUSparkleErrorDomain && [SUError.noUpdateError, .installationCanceledError].contains { Int($0.rawValue) == error.code }) {
            statusItem.title = availableUpdate == nil ? "Couldn’t check for updates" : "Update couldn’t complete"
            statusItem.toolTip = error.localizedDescription
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
