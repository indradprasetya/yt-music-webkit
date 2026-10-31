import AppKit

enum MusicMenuSymbol {
    static func set(_ name: String, on item: NSMenuItem, description: String) {
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
    }
}
