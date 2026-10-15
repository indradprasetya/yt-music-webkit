import AppKit
import UniformTypeIdentifiers

final class MusicSettings: NSWindowController {
    private let icons: MusicAppIcons
    private var previews: [MusicAppIcons.Appearance: NSImageView] = [:]
    private var labels: [MusicAppIcons.Appearance: NSTextField] = [:]
    private var resetButton: NSButton!
    private var status: NSTextField!

    init(icons: MusicAppIcons) {
        self.icons = icons
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        icons.onChange = { [weak self] in self?.refresh() }
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        let host = window!.contentView!
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
