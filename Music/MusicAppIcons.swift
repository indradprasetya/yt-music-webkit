import AppKit

final class MusicAppIcons {
    enum Appearance: String, CaseIterable {
        case light, dark

        var title: String { rawValue.capitalized }
    }

    enum IconError: LocalizedError {
        case invalidFile
        case tooLarge
        case applicationNotWritable

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Choose a valid .icns file. The selected file could not be read as an app icon."
            case .tooLarge: return "Choose an .icns file smaller than 32 MB."
            case .applicationNotWritable: return "Music’s icon in Finder couldn’t be changed. Move Music to a writable Applications folder, then reopen it."
            }
        }
    }

    private let storageURL: URL
    private let applicationURL: URL
    private let iconStyle: () -> String?
    private var data: [String: Data] = [:]
    private var images: [Appearance: NSImage] = [:]
    private var observation: NSKeyValueObservation?
    private var iconStyleTimer: Timer?
    private var appliedImage: NSImage?
    private var hasAppliedIcon = false
    private var nativeDarkIcon: NativeIcon?
    private var nativeRenderKey: String?
    private(set) var loadError: Error?
    private(set) var finderError: Error?
    var onChange: (() -> Void)?
    var hasCustomIcons: Bool { !data.isEmpty || loadError != nil || finderError != nil }

    init(storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Music", isDirectory: true)
        .appendingPathComponent("CustomIcons.plist"),
         applicationURL: URL = Bundle.main.bundleURL,
         iconStyle: @escaping () -> String? = {
             CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
             return CFPreferencesCopyValue("AppleIconAppearanceTheme" as CFString,
                                           kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                           kCFPreferencesAnyHost) as? String
         }) {
        self.storageURL = storageURL
        self.applicationURL = applicationURL
        self.iconStyle = iconStyle
        do {
            let saved = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: storageURL))
            for appearance in Appearance.allCases {
                guard let bytes = saved[appearance.rawValue] else { continue }
                do {
                    images[appearance] = try Self.decode(bytes)
                    data[appearance.rawValue] = bytes
                    if appearance == .dark { nativeDarkIcon = try NativeIcon(data: bytes) }
                } catch {
                    loadError = error
                }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation uses the bundled icon, including native icon styles.
        } catch {
            loadError = error
        }
    }

    deinit { iconStyleTimer?.invalidate() }

    func start() {
        if #available(macOS 26.0, *) {
            iconStyleTimer?.invalidate()
            // Global preference changes can arrive late unless the process refreshes its cache.
            iconStyleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.hasCustomIcons else { return }
                self.apply(appearance: NSApp.effectiveAppearance)
            }
            iconStyleTimer?.tolerance = 0.2
        }
        observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            self?.apply(appearance: app.effectiveAppearance)
        }
    }

    func image(for appearance: Appearance) -> NSImage? { images[appearance] }

    func importIcon(from url: URL, for appearance: Appearance) throws {
        guard url.pathExtension.lowercased() == "icns" else { throw IconError.invalidFile }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw IconError.tooLarge }
        let bytes = try Data(contentsOf: url)
        let image = try Self.decode(bytes)
        let nativeIcon = appearance == .dark ? try NativeIcon(data: bytes) : nil
        var updated = data
        updated[appearance.rawValue] = bytes
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let saved = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try saved.write(to: storageURL, options: .atomic)
        data = updated
        images[appearance] = image
        if appearance == .dark { nativeDarkIcon = nativeIcon }
        nativeRenderKey = nil
        loadError = nil
        apply(appearance: NSApp.effectiveAppearance)
        onChange?()
        if let finderError { throw finderError }
    }

    func reset() throws {
        guard NSWorkspace.shared.setIcon(nil, forFile: applicationURL.path, options: []) else {
            finderError = IconError.applicationNotWritable
            onChange?()
            throw IconError.applicationNotWritable
        }
        do { try FileManager.default.removeItem(at: storageURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch {
            NSWorkspace.shared.setIcon(appliedImage, forFile: applicationURL.path, options: [])
            throw error
        }
        data = [:]
        images = [:]
        nativeDarkIcon = nil
        nativeRenderKey = nil
        loadError = nil
        finderError = nil
        NSApp.applicationIconImage = nil
        appliedImage = nil
        hasAppliedIcon = true
        onChange?()
    }

    func apply(appearance: NSAppearance) {
        var variant: Appearance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        var systemEffect = false
        var style: String?
        // shortcut: macOS exposes icon style through an undocumented preference; use a public API when available.
        if #available(macOS 26.0, *) {
            style = iconStyle()
            switch style {
            case nil: variant = .light
            case "RegularDark": variant = .dark
            case "ClearLight", "ClearDark", "ClearAutomatic", "TintedLight", "TintedDark", "TintedAutomatic":
                variant = .dark
                systemEffect = true
            default: break // Automatic and unknown styles follow the system appearance.
            }
        }
        if systemEffect, let nativeDarkIcon {
            let preferences = CFPreferencesCopyMultiple(nil, kCFPreferencesAnyApplication,
                                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
            let colors = preferences.keys.filter { $0.hasPrefix("AppleIconAppearance") || $0 == "AppleAccentColor" }
                .sorted().map { "\($0)=\(preferences[$0]!)" }.joined(separator: ";")
            let key = "\(style ?? "")/\(appearance.name.rawValue)/\(colors)"
            guard nativeRenderKey != key else { return }
            let image = NSWorkspace.shared.icon(forFile: nativeDarkIcon.url.path)
            image.recache()
            applyImage(image)
            nativeRenderKey = key
            return
        }
        nativeRenderKey = nil
        applyImage(images[variant])
    }

    private func applyImage(_ image: NSImage?) {
        guard !hasAppliedIcon || appliedImage !== image else { return }
        // Finder keeps this icon while Music is closed; launch reapplies it after an app update.
        if image != nil || appliedImage != nil || hasCustomIcons {
            finderError = NSWorkspace.shared.setIcon(image, forFile: applicationURL.path, options: [])
                ? nil : IconError.applicationNotWritable
        }
        NSApp.applicationIconImage = image
        appliedImage = image
        hasAppliedIcon = true
        onChange?()
    }

    final class NativeIcon {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Music-Icon-\(UUID().uuidString).app")

        init(data: Data) throws {
            // An isolated icon-only bundle lets IconServices apply the same materials as bundled app icons.
            let contents = url.appendingPathComponent("Contents")
            do {
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                try data.write(to: contents.appendingPathComponent("Resources/Icon.icns"), options: .atomic)
                let info = ["CFBundleIdentifier": "local.music-icon.\(UUID().uuidString)",
                            "CFBundleName": "Music Icon", "CFBundlePackageType": "APPL",
                            "CFBundleExecutable": "Icon", "CFBundleIconFile": "Icon.icns"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
                let executable = contents.appendingPathComponent("MacOS/Icon")
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func decode(_ data: Data) throws -> NSImage {
        guard data.count <= 32 * 1024 * 1024 else { throw IconError.tooLarge }
        guard data.count >= 8, data.prefix(4) == Data("icns".utf8),
              data[4..<8].reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == data.count,
              let image = NSImage(data: data), image.isValid,
              image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            throw IconError.invalidFile
        }
        return image
    }
}
