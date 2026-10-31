import AppKit
import UniformTypeIdentifiers

final class MusicSettings: NSWindowController {
    private final class ExtensionList: NSStackView {
        override var isFlipped: Bool { true }
    }

    private let icons: MusicAppIcons
    private let extensions: MusicExtensions?
    private var extensionRows: NSStackView?
    private var extensionStatus: NSTextField?
    private var applyExtensionsButton: NSButton?
    private let reloadPage: (() -> Void)?
    private var applyingExtensions = false
    private var extensionFeedback: String?
    private var extensionFeedbackIsError = false
    private var previews: [MusicAppIcons.Appearance: NSImageView] = [:]
    private var labels: [MusicAppIcons.Appearance: NSTextField] = [:]
    private var resetButton: NSButton!
    private var status: NSTextField!

    init(icons: MusicAppIcons, extensions: MusicExtensions? = nil, reloadPage: (() -> Void)? = nil) {
        self.icons = icons
        self.extensions = extensions
        self.reloadPage = reloadPage
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        icons.onChange = { [weak self] in self?.refresh() }
        extensions?.onChange = { [weak self] in self?.refreshExtensions() }
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show() {
        extensions?.scan()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        let host: NSView
        if extensions != nil {
            let tabs = NSTabView(frame: window!.contentView!.bounds.insetBy(dx: 12, dy: 8))
            tabs.translatesAutoresizingMaskIntoConstraints = false
            // Size tab hosts before their fixed-size contents participate in layout.
            let iconsTab = NSTabViewItem(identifier: "icons")
            iconsTab.label = "App Icon"
            iconsTab.view = NSView(frame: tabs.contentRect)
            tabs.addTabViewItem(iconsTab)
            let extensionsTab = NSTabViewItem(identifier: "extensions")
            extensionsTab.label = "Extensions"
            extensionsTab.view = NSView(frame: tabs.contentRect)
            tabs.addTabViewItem(extensionsTab)
            window!.contentView!.addSubview(tabs)
            NSLayoutConstraint.activate([
                tabs.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 12),
                tabs.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -12),
                tabs.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 8),
                tabs.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor, constant: -8)
            ])
            host = iconsTab.view!
            buildExtensions(in: extensionsTab.view!)
        } else {
            host = window!.contentView!
        }
        let heading = NSTextField(labelWithString: "App Icon")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let description = text("Choose an icon for each macOS icon style.")
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

        let content = NSStackView(views: [heading, description, columns, help, status, resetButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(20, after: description)
        content.setCustomSpacing(20, after: columns)
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -24),
            columns.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func buildExtensions(in host: NSView) {
        let description = text("Extensions installed from the App Store appear here. Enable only extensions you trust.")
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rows = ExtensionList()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false
        extensionRows = rows
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        let status = text("")
        status.textColor = .systemRed
        extensionStatus = status
        let refresh = NSButton(title: "Refresh List", target: self, action: #selector(refreshExtensionList))
        refresh.toolTip = "Check for newly installed or removed extensions."
        let getExtensions = NSButton(title: "Get Extensions…", target: self, action: #selector(browseExtensions))
        getExtensions.toolTip = "Browse Safari extensions in the App Store."
        getExtensions.setAccessibilityLabel("Get extensions, opens the App Store")
        let apply = NSButton(title: "Apply Extensions", target: self, action: #selector(applyExtensions))
        apply.toolTip = "Reload YouTube Music to apply changes. Settings stays open."
        applyExtensionsButton = apply
        let actions = NSStackView(views: [refresh, getExtensions, NSView(), apply])
        actions.spacing = 12
        let reloadHint = text("Apply reloads YouTube Music. Playback may pause.")
        reloadHint.textColor = .secondaryLabelColor
        let content = NSStackView(views: [description, scroll, status, actions, reloadHint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),
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
            button.isEnabled = !extensions.isBusy(entry) && !applyingExtensions
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = entry.name
            let open = NSButton(title: "Open", target: self, action: #selector(openExtension(_:)))
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
        extensionStatus?.stringValue = extensions.errorMessage ?? extensionFeedback ?? ""
        extensionStatus?.textColor = extensions.errorMessage != nil || extensionFeedbackIsError ? .systemRed : .secondaryLabelColor
        extensionStatus?.isHidden = extensionStatus?.stringValue.isEmpty == true
        applyExtensionsButton?.isEnabled = reloadPage != nil && !applyingExtensions && !extensions.isWorking && extensions.errorMessage == nil
    }

    @objc private func refreshExtensionList() {
        extensionFeedback = nil
        extensions?.scan()
    }

    @objc private func applyExtensions() {
        guard let extensions, !extensions.isWorking, extensions.errorMessage == nil,
              !applyingExtensions, let reloadPage else { return }
        applyingExtensions = true
        extensionFeedback = "Reloading YouTube Music…"
        extensionFeedbackIsError = false
        refreshExtensions()
        reloadPage()
    }

    func pageLoadFinished(error: Error? = nil) {
        guard applyingExtensions else { return }
        applyingExtensions = false
        extensionFeedback = error.map { "Couldn’t reload YouTube Music: \($0.localizedDescription)" } ?? "Changes applied."
        extensionFeedbackIsError = error != nil
        refreshExtensions()
    }

    @objc private func browseExtensions() {
        if !NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/story/id1377753262?platform=mac")!) {
            NSSound.beep()
        }
    }

    @objc private func toggleExtension(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let entry = extensions?.entries.first(where: { $0.id == id }) else { return }
        extensionFeedback = nil
        extensions?.setEnabled(sender.state == .on, for: entry)
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
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        return label
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
