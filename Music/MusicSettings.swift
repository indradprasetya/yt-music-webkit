import AppKit
import UniformTypeIdentifiers

final class MusicSettings: NSWindowController {
    private final class Panes: NSTabViewController {
        var onSelection: ((NSTabViewItem) -> Void)?

        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            if let tabViewItem { onSelection?(tabViewItem) }
        }
    }

    private final class ExtensionList: NSStackView {
        override var isFlipped: Bool { true }
    }

    private let icons: MusicAppIcons
    private let extensions: MusicExtensions?
    private let scripts: MusicScripts?
    private let lyrics: MusicLyrics?
    private var extensionRows: NSStackView?
    private var extensionStatus: NSTextField?
    private var applyExtensionsButton: NSButton?
    private let reloadPage: (() -> Void)?
    private var isApplying = false
    private var applyFeedback: String?
    private var applyFeedbackIsError = false
    private var scriptRows: NSStackView?
    private var scriptStatus: NSTextField?
    private var importScriptButton: NSButton?
    private var applyScriptsButton: NSButton?
    private var scriptError: String?
    private var lyricsToggle: NSButton?
    private var lyricsStatus: NSTextField?
    private let updateLyrics: ((@escaping (Error?) -> Void) -> Void)?
    private var isUpdatingLyrics = false
    private var lyricsError: String?
    private var previews: [MusicAppIcons.Appearance: NSImageView] = [:]
    private var labels: [MusicAppIcons.Appearance: NSTextField] = [:]
    private var resetButton: NSButton!
    private var status: NSTextField!

    init(icons: MusicAppIcons, extensions: MusicExtensions? = nil, scripts: MusicScripts? = nil,
         lyrics: MusicLyrics? = nil, reloadPage: (() -> Void)? = nil,
         updateLyrics: ((@escaping (Error?) -> Void) -> Void)? = nil) {
        self.icons = icons
        self.extensions = extensions
        self.scripts = scripts
        self.lyrics = lyrics
        self.reloadPage = reloadPage
        self.updateLyrics = updateLyrics
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        icons.onChange = { [weak self] in self?.refresh() }
        extensions?.onChange = { [weak self] in self?.refreshExtensions(); self?.refreshScripts(); self?.refreshLyrics() }
        scripts?.onChange = { [weak self] in
            self?.scriptError = nil
            self?.applyFeedback = nil
            self?.refreshScripts()
            self?.refreshExtensions()
        }
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show() {
        extensions?.scan()
        showWindow(nil)
        window?.toolbar?.allowsUserCustomization = false
        window?.toolbar?.allowsDisplayModeCustomization = false
        window?.toolbar?.displayMode = .iconAndLabel
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        let host: NSView
        if extensions != nil || scripts != nil || lyrics != nil {
            let panes = Panes()
            panes.tabStyle = .toolbar
            panes.transitionOptions = []
            panes.canPropagateSelectedChildViewControllerTitle = true
            panes.view.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
            func addPane(_ identifier: String, title: String, symbol: String) -> NSView {
                let controller = NSViewController()
                controller.title = title
                controller.view = NSView(frame: panes.view.bounds)
                controller.preferredContentSize = panes.view.bounds.size
                let item = NSTabViewItem(viewController: controller)
                item.identifier = identifier
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                panes.addTabViewItem(item)
                return controller.view
            }
            host = addPane("icons", title: "App Icon", symbol: "app")
            if extensions != nil {
                buildExtensions(in: addPane("extensions", title: "Extensions", symbol: "puzzlepiece.extension"))
            }
            if scripts != nil {
                buildScripts(in: addPane("scripts", title: "Scripts", symbol: "applescript"))
            }
            if lyrics != nil {
                buildLyrics(in: addPane("lyrics", title: "Lyrics", symbol: "text.quote"))
            }
            panes.onSelection = { [weak self] in self?.selectPane($0) }
            window!.toolbarStyle = .preference
            window!.contentViewController = panes
            if let selected = panes.tabView.selectedTabViewItem { selectPane(selected) }
        } else {
            host = window!.contentView!
        }
        let header = sectionHeader("App Icons", description: "Choose an icon for each macOS icon style.")
        let columns = NSStackView(views: MusicAppIcons.Appearance.allCases.map(makeColumn))
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.spacing = 24

        let format = text("Use an .icns file. Find more icons at")
        let link = NSButton(title: "macosicons.com", target: self, action: #selector(browseIcons))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 12)
        link.setAccessibilityLabel("Download icons from macosicons.com, opens in your browser")
        let help = NSStackView(views: [format, link])
        help.spacing = 4
        help.alignment = .firstBaseline

        status = text("")
        status.textColor = .systemRed
        resetButton = NSButton(title: "Reset to Default", target: self, action: #selector(reset))
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = "Restore Music’s original icon for every appearance."

        let content = NSStackView(views: [header, columns, help, status, resetButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(20, after: header)
        content.setCustomSpacing(20, after: columns)
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -24),
            columns.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func selectPane(_ item: NSTabViewItem) {
        window?.title = item.label
        let identifier = item.identifier as? String
        applyExtensionsButton?.keyEquivalent = identifier == "extensions" ? "\r" : ""
        applyScriptsButton?.keyEquivalent = identifier == "scripts" ? "\r" : ""
        let button = identifier == "extensions" ? applyExtensionsButton
            : identifier == "scripts" ? applyScriptsButton : nil
        window?.defaultButtonCell = button?.cell as? NSButtonCell
    }

    private func buildExtensions(in host: NSView) {
        let header = sectionHeader("Installed Extensions", description: "Extensions installed from the App Store appear here. Enable only extensions you trust.")
        let rows = ExtensionList()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false
        extensionRows = rows
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        let status = text("")
        status.textColor = .systemRed
        extensionStatus = status
        let refresh = NSButton(title: "Refresh List", target: self, action: #selector(refreshExtensionList))
        refresh.bezelStyle = .rounded
        refresh.toolTip = "Check for newly installed or removed extensions."
        let getExtensions = NSButton(title: "Get Extensions…", target: self, action: #selector(browseExtensions))
        getExtensions.bezelStyle = .rounded
        getExtensions.toolTip = "Browse Safari extensions in the App Store."
        getExtensions.setAccessibilityLabel("Get extensions, opens the App Store")
        let apply = NSButton(title: "Apply Extensions", target: self, action: #selector(applyExtensions))
        apply.bezelStyle = .rounded
        apply.toolTip = "Reload YouTube Music to apply changes. Settings stays open."
        applyExtensionsButton = apply
        let actions = NSStackView(views: [refresh, getExtensions, NSView(), apply])
        actions.spacing = 8
        let reloadHint = text("Apply reloads YouTube Music. Playback may pause.")
        reloadHint.textColor = .secondaryLabelColor
        let content = NSStackView(views: [header, scroll, status, actions, reloadHint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.setCustomSpacing(16, after: header)
        content.setCustomSpacing(8, after: actions)
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 220)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140), preferredHeight,
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        refreshExtensions()
    }

    private func refreshExtensions() {
        guard let extensions, let rows = extensionRows else { return }
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        if extensions.entries.isEmpty { rows.addArrangedSubview(text("No Safari Web Extensions installed.")) }
        for entry in extensions.entries {
            let button = NSButton(checkboxWithTitle: entry.name, target: self, action: #selector(toggleExtension(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(entry.id)
            button.state = extensions.isEnabled(entry) ? .on : .off
            button.isEnabled = !extensions.isBusy(entry) && !isApplying
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = entry.name
            let open = NSButton(title: "Open", target: self, action: #selector(openExtension(_:)))
            open.bezelStyle = .rounded
            open.identifier = NSUserInterfaceItemIdentifier(entry.id)
            let row = NSStackView(views: [button, open])
            row.alignment = .centerY
            row.detachesHiddenViews = false
            open.isHidden = !extensions.hasAction(entry)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32).isActive = true
            if extensions.usesNativeMessaging(entry) {
                let note = text("Native app features aren’t available in Music.")
                note.textColor = .secondaryLabelColor
                rows.addArrangedSubview(note)
                note.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
        }
        extensionStatus?.stringValue = extensions.errorMessage ?? applyFeedback ?? ""
        extensionStatus?.textColor = extensions.errorMessage != nil || applyFeedbackIsError ? .systemRed : .secondaryLabelColor
        extensionStatus?.isHidden = extensionStatus?.stringValue.isEmpty == true
        applyExtensionsButton?.isEnabled = reloadPage != nil && !isApplying && !extensions.isWorking && extensions.errorMessage == nil
    }

    @objc private func refreshExtensionList() {
        applyFeedback = nil
        extensions?.scan()
    }

    @objc private func applyExtensions() {
        guard let extensions, !extensions.isWorking, extensions.errorMessage == nil,
              !isApplying else { return }
        applyChanges()
    }

    private func applyChanges() {
        guard !isApplying, let reloadPage else { return }
        isApplying = true
        scriptError = nil
        applyFeedback = "Reloading YouTube Music…"
        applyFeedbackIsError = false
        refreshExtensions()
        refreshScripts()
        refreshLyrics()
        reloadPage()
    }

    func pageLoadFinished(error: Error? = nil) {
        guard isApplying else { return }
        isApplying = false
        applyFeedback = error.map { "Couldn’t reload YouTube Music: \($0.localizedDescription)" } ?? "Changes applied."
        applyFeedbackIsError = error != nil
        refreshExtensions()
        refreshScripts()
        refreshLyrics()
    }

    @objc private func browseExtensions() {
        if !NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/story/id1377753262?platform=mac")!) {
            NSSound.beep()
        }
    }

    @objc private func toggleExtension(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let entry = extensions?.entries.first(where: { $0.id == id }) else { return }
        applyFeedback = nil
        extensions?.setEnabled(sender.state == .on, for: entry)
    }

    private func buildScripts(in host: NSView) {
        let header = sectionHeader("Your Scripts", description: "Customize YouTube Music with your own scripts. Only enable scripts you trust.")
        let rows = ExtensionList()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scriptRows = rows
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        let status = text("")
        scriptStatus = status
        let importScript = NSButton(title: "Import Script…", target: self, action: #selector(importScript))
        importScript.bezelStyle = .rounded
        importScript.toolTip = "Import a local JavaScript (.js) file. It starts off."
        importScriptButton = importScript
        let apply = NSButton(title: "Apply Scripts", target: self, action: #selector(applyScripts))
        apply.bezelStyle = .rounded
        apply.toolTip = "Reload YouTube Music to apply changes. Settings stays open."
        applyScriptsButton = apply
        let actions = NSStackView(views: [importScript, NSView(), apply])
        actions.spacing = 8
        let hint = text("Apply reloads YouTube Music. Playback may pause.")
        hint.textColor = .secondaryLabelColor
        let content = NSStackView(views: [header, scroll, status, actions, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.setCustomSpacing(16, after: header)
        content.setCustomSpacing(8, after: actions)
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 220)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140), preferredHeight,
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        refreshScripts()
    }

    private func buildLyrics(in host: NSView) {
        let header = sectionHeader("Synced Lyrics (Beta)", description: "Follow lyrics in time with your music.")
        let toggle = NSButton(checkboxWithTitle: "Enable synced lyrics", target: self, action: #selector(toggleLyrics(_:)))
        toggle.state = lyrics?.isEnabled == true ? .on : .off
        lyricsToggle = toggle

        let status = text("")
        lyricsStatus = status
        toggle.toolTip = "Turn synced lyrics on or off immediately, without reloading YouTube Music."
        let hint = text("Changes take effect immediately. Playback keeps going.")
        func groupTitle(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            return label
        }
        func bullets(_ items: [String]) -> NSTextField {
            let label = text(items.map { "•\t\($0)" }.joined(separator: "\n"))
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = 12
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
            paragraph.paragraphSpacing = 4
            label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ])
            return label
        }
        let usageTitle = groupTitle("Using lyrics")
        let usage = bullets([
            "Click a timed line to jump to that part of the song.",
            "Use the gear button in Lyrics to adjust timing for the current song.",
            "When synced lyrics aren’t available, plain lyrics are shown."
        ])
        let privacyTitle = groupTitle("Privacy & storage")
        let privacy = bullets([
            "When enabled, song titles and artists are sent to NetEase Cloud Music, with LRCLIB as a fallback.",
            "Providers receive your IP address. Your YouTube account cookies aren’t shared.",
            "Lyrics stay in memory and aren’t saved to disk.",
            "Only nonzero offsets and song IDs are saved locally. Reset to 0 to remove a saved offset."
        ])

        let content = NSStackView(views: [header, toggle, hint, usageTitle, usage, privacyTitle, privacy, status])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(16, after: header)
        content.setCustomSpacing(20, after: hint)
        content.setCustomSpacing(4, after: usageTitle)
        content.setCustomSpacing(20, after: usage)
        content.setCustomSpacing(4, after: privacyTitle)
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -24),
            privacy.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            usage.widthAnchor.constraint(equalTo: content.widthAnchor),
            hint.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        refreshLyrics()
    }

    private func refreshLyrics() {
        guard let lyrics else { return }
        lyricsToggle?.state = lyrics.isEnabled ? .on : .off
        lyricsToggle?.isEnabled = updateLyrics != nil && !isApplying && !isUpdatingLyrics
        lyricsStatus?.stringValue = lyricsError ?? (isUpdatingLyrics ? "Updating lyrics…" : "")
        lyricsStatus?.textColor = lyricsError != nil ? .systemRed : .secondaryLabelColor
        lyricsStatus?.isHidden = lyricsStatus?.stringValue.isEmpty == true
    }

    @objc private func toggleLyrics(_ sender: NSButton) {
        guard !isApplying, !isUpdatingLyrics, let updateLyrics else { return }
        lyrics?.isEnabled = sender.state == .on
        lyricsError = nil
        isUpdatingLyrics = true
        refreshLyrics()
        updateLyrics { [weak self] error in
            self?.isUpdatingLyrics = false
            self?.lyricsError = error.map { "Couldn’t update lyrics: \($0.localizedDescription) Use View → Reload to retry." }
            self?.refreshLyrics()
        }
    }

    private func refreshScripts() {
        guard let scripts, let rows = scriptRows else { return }
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        if scripts.entries.isEmpty { rows.addArrangedSubview(text("No scripts imported. Choose Import Script to add a .js file.")) }
        for entry in scripts.entries {
            let toggle = NSButton(checkboxWithTitle: entry.name, target: self, action: #selector(toggleScript(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
            toggle.state = entry.isEnabled ? .on : .off
            toggle.isEnabled = !isApplying
            toggle.cell?.lineBreakMode = .byTruncatingTail
            toggle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            toggle.toolTip = entry.name
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeScript(_:)))
            remove.bezelStyle = .rounded
            remove.identifier = toggle.identifier
            remove.isEnabled = !isApplying
            remove.setAccessibilityLabel("Remove \(entry.name) from Music")
            let row = NSStackView(views: [toggle, NSView(), remove])
            row.alignment = .centerY
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -32).isActive = true
        }
        let error = scripts.loadError?.localizedDescription ?? scriptError
        scriptStatus?.stringValue = error ?? applyFeedback ?? ""
        scriptStatus?.textColor = error != nil || applyFeedbackIsError ? .systemRed : .secondaryLabelColor
        scriptStatus?.isHidden = scriptStatus?.stringValue.isEmpty == true
        importScriptButton?.isEnabled = !isApplying && scripts.loadError == nil
        applyScriptsButton?.isEnabled = reloadPage != nil && !isApplying && extensions?.isWorking != true && scripts.loadError == nil
    }

    @objc private func importScript() {
        guard let window, let scripts, !isApplying else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Script"
        panel.prompt = "Import Script"
        panel.allowedContentTypes = [.javaScript]
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try scripts.importScript(from: url) }
            catch { self.scriptError = error.localizedDescription; self.refreshScripts() }
        }
    }

    @objc private func toggleScript(_ sender: NSButton) {
        guard !isApplying, let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        do { try scripts?.setEnabled(sender.state == .on, for: id) }
        catch { scriptError = error.localizedDescription; refreshScripts() }
    }

    @objc private func removeScript(_ sender: NSButton) {
        guard !isApplying, let window, let scripts,
              let value = sender.identifier?.rawValue, let id = UUID(uuidString: value),
              let entry = scripts.entries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.name)?"
        alert.informativeText = "The saved copy will be removed from Music. The original file won’t be changed. Apply Scripts to update the page."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try scripts.remove(id: id) }
            catch { self.scriptError = error.localizedDescription; self.refreshScripts() }
        }
    }

    @objc private func applyScripts() {
        guard scripts?.loadError == nil, scripts != nil, extensions?.isWorking != true else { return }
        applyChanges()
    }

    @objc private func openExtension(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let entry = extensions?.entries.first(where: { $0.id == id }) else { return }
        extensions?.performAction(for: entry, from: sender)
    }

    private func makeColumn(_ appearance: MusicAppIcons.Appearance) -> NSView {
        let title = NSTextField(labelWithString: appearance.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel("\(appearance.title) app icon preview")
        previews[appearance] = preview
        let label = text("Default")
        labels[appearance] = label
        let choose = NSButton(title: "Choose Icon…", target: self, action: #selector(chooseIcon(_:)))
        choose.bezelStyle = .rounded
        choose.identifier = NSUserInterfaceItemIdentifier(appearance.rawValue)
        choose.setAccessibilityLabel("Choose \(appearance.rawValue) app icon")
        let column = NSStackView(views: [title, preview, label, choose])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 96),
            preview.heightAnchor.constraint(equalToConstant: 96)
        ])
        return column
    }

    private func text(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func sectionHeader(_ title: String, description: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let detail = text(description)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, detail])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        return header
    }

    private func refresh() {
        for appearance in MusicAppIcons.Appearance.allCases {
            let custom = icons.image(for: appearance)
            previews[appearance]?.image = custom ?? NSImage(named: appearance.title)
            labels[appearance]?.stringValue = custom == nil ? "Default" : "Custom .icns"
        }
        resetButton.isEnabled = icons.hasCustomIcons
        status.stringValue = icons.loadError != nil
            ? "A saved icon could not be loaded. Choose it again or reset to default."
            : icons.finderError?.localizedDescription ?? ""
        status.isHidden = status.stringValue.isEmpty
    }

    @objc private func chooseIcon(_ sender: NSButton) {
        guard let window, let name = sender.identifier?.rawValue,
              let appearance = MusicAppIcons.Appearance(rawValue: name) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose \(appearance.title) Icon"
        panel.prompt = "Choose Icon"
        panel.allowedContentTypes = [.icns]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.icons.importIcon(from: url, for: appearance) }
            catch { self.show(error: error) }
        }
    }

    @objc private func reset() {
        do { try icons.reset() }
        catch { show(error: error) }
    }

    @objc private func browseIcons() {
        if !NSWorkspace.shared.open(URL(string: "https://macosicons.com")!) { NSSound.beep() }
    }

    private func show(error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t Update App Icon"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
