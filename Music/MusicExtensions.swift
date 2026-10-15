import AppKit
import WebKit

@MainActor
final class MusicExtensions: NSObject, WKWebExtensionControllerDelegate, WKWebExtensionTab, WKWebExtensionWindow {
    struct Entry: Equatable {
        let id: String
        let name: String
        let url: URL
    }

    let controller = WKWebExtensionController()
    private weak var webView: WKWebView?
    private weak var window: NSWindow?
    private weak var popupAnchor: NSView?
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var pending: Set<String> = []
    private var isScanning = false
    private let defaults = UserDefaults.standard
    private let enabledKey = "MusicEnabledExtensions"
    private let approvedKey = "MusicApprovedExtensions"
    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?
    var errorMessage: String?

    override init() {
        super.init()
        controller.delegate = self
    }

    func attach(webView: WKWebView, window: NSWindow) {
        self.webView = webView
        self.window = window
        controller.didOpenWindow(self)
        controller.didOpenTab(self)
        controller.didActivateTab(self)
        scan()
    }

    func pageChanged() { controller.didChangeTabProperties([.loading, .title, .URL], for: self) }

    func isEnabled(_ entry: Entry) -> Bool { contexts[entry.id] != nil }
    func isBusy(_ entry: Entry) -> Bool { pending.contains(entry.id) }
    func hasAction(_ entry: Entry) -> Bool { contexts[entry.id]?.action(for: self) != nil }

    func performAction(for entry: Entry, from view: NSView) {
        guard let context = contexts[entry.id] else { return }
        popupAnchor = view
        context.performAction(for: self)
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            defer { isScanning = false }
            let found = await Task.detached { Self.discover() }.value
            guard let found else {
                errorMessage = "Couldn’t find installed extensions. Try Refresh."
                onChange?()
                return
            }
            errorMessage = nil
            entries = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // shortcut: Installed extension updates apply after restarting Music; reload live contexts if hot updates are needed.
            let available = Set(entries.map(\.id))
            for (id, context) in contexts where !available.contains(id) {
                do {
                    try controller.unload(context)
                    contexts.removeValue(forKey: id)
                } catch { errorMessage = "Couldn’t unload a removed extension: \(error.localizedDescription)" }
            }
            var saved = Set(defaults.stringArray(forKey: enabledKey) ?? [])
            saved.formIntersection(available)
            defaults.set(Array(saved), forKey: enabledKey)
            onChange?()
            for entry in entries where saved.contains(entry.id) && contexts[entry.id] == nil && !pending.contains(entry.id) {
                pending.insert(entry.id)
                onChange?()
                do { try await enable(entry, restoring: true) }
                catch { errorMessage = "Couldn’t load \(entry.name): \(error.localizedDescription)"; onChange?() }
                pending.remove(entry.id)
                onChange?()
            }
        }
    }

    func setEnabled(_ enabled: Bool, for entry: Entry) {
        guard !pending.contains(entry.id) else { return }
        if !enabled {
            if let context = contexts[entry.id] {
                do {
                    try controller.unload(context)
                    contexts.removeValue(forKey: entry.id)
                } catch {
                    errorMessage = "Couldn’t disable \(entry.name): \(error.localizedDescription)"
                    onChange?()
                    return
                }
            }
            var saved = Set(defaults.stringArray(forKey: enabledKey) ?? [])
            saved.remove(entry.id)
            defaults.set(Array(saved), forKey: enabledKey)
            onChange?()
            return
        }
        pending.insert(entry.id)
        onChange?()
        Task {
            do { try await enable(entry, restoring: false) }
            catch { errorMessage = error.localizedDescription; onChange?() }
            pending.remove(entry.id)
            onChange?()
        }
    }

    private func enable(_ entry: Entry, restoring: Bool) async throws {
        guard contexts[entry.id] == nil, let bundle = Bundle(url: entry.url) else { return }
        let ext = try await WKWebExtension(appExtensionBundle: bundle)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = entry.id
        let approval = "\(entry.id):\(ext.displayVersion ?? "")"
        var approved = defaults.dictionary(forKey: approvedKey) as? [String: Bool] ?? [:]
        if approved[approval] != true {
            guard !restoring else { throw NSError(domain: "MusicExtensions", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Permission must be confirmed in Settings."]) }
            let permissionNames = ext.requestedPermissions.map(\.rawValue).sorted().joined(separator: ", ")
            let sites = ext.allRequestedMatchPatterns.map(\.string).sorted().joined(separator: ", ")
            guard await confirm("Allow \(entry.name) in Music?",
                "This extension requests: \(permissionNames.isEmpty ? "no browser APIs" : permissionNames). Website access: \(sites.isEmpty ? "none" : sites). Only enable extensions you trust.") else { return }
            approved[approval] = true
            defaults.set(approved, forKey: approvedKey)
        }
        let expires = Date.distantFuture
        context.grantedPermissions = Dictionary(uniqueKeysWithValues: ext.requestedPermissions.map { ($0, expires) })
        context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: ext.allRequestedMatchPatterns.map { ($0, expires) })
        try controller.load(context)
        contexts[entry.id] = context
        var saved = Set(defaults.stringArray(forKey: enabledKey) ?? [])
        saved.insert(entry.id)
        defaults.set(Array(saved), forKey: enabledKey)
        errorMessage = nil
        onChange?()
    }

    private func confirm(_ title: String, _ detail: String) async -> Bool {
        guard let window = NSApp.keyWindow ?? window else { return false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    nonisolated static func discover() -> [Entry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-vvv", "-p", "com.apple.Safari.web-extension"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        return installedExtensions(in: output)
    }

    nonisolated static func installedExtensions(in output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "Path = ") else { return nil }
            let url = URL(fileURLWithPath: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            guard url.pathExtension == "appex", let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary,
                  let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                  point == "com.apple.Safari.web-extension",
                  let id = bundle.bundleIdentifier,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/manifest.json").path) else { return nil }
            return Entry(id: id, name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? id, url: url)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [self] }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let anchor = popupAnchor ?? webView, let popover = action.popupPopover else {
            completionHandler(NSError(domain: "MusicExtensions", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Extension popup is unavailable."]))
            return
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let allowed = await confirm("Extension permissions", permissions.map(\.rawValue).sorted().joined(separator: ", "))
        return (allowed ? permissions : [], nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let allowed = await confirm("Extension website access", patterns.map(\.string).sorted().joined(separator: ", "))
        return (allowed ? patterns : [], nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let allowed = await confirm("Extension website access", urls.map(\.absoluteString).sorted().joined(separator: ", "))
        return (allowed ? urls : [], nil)
    }
}
