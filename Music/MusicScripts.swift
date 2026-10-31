import Foundation
import JavaScriptCore
import WebKit

@MainActor
final class MusicScripts {
    struct Entry: Codable, Equatable {
        let id: UUID
        let name: String
        let source: String
        let runAtStart: Bool
        var isEnabled: Bool
    }

    private let storageURL: URL
    private var installedScripts: [WKUserScript] = []
    private(set) var entries: [Entry] = []
    private(set) var loadError: Error?
    var onChange: (() -> Void)?

    init(storageURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Music", isDirectory: true)
        .appendingPathComponent("CustomScripts.plist")) {
        self.storageURL = storageURL
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let saved = try PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: storageURL))
            guard Set(saved.map(\.id)).count == saved.count else { throw Self.invalid("Duplicate saved scripts.") }
            for entry in saved { _ = try Self.validate(entry.source) }
            entries = saved
        } catch {
            loadError = Self.invalid("Saved scripts couldn’t be read. Restore CustomScripts.plist in Music’s Application Support folder, then reopen Music. The saved file hasn’t been changed.")
        }
    }

    func importScript(from url: URL) throws {
        guard url.pathExtension.lowercased() == "js",
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Self.invalid("Choose a JavaScript (.js) file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, let source = String(data: data, encoding: .utf8) else {
            throw Self.invalid("Choose a UTF-8 JavaScript file no larger than 1 MB.")
        }
        let metadata = try Self.validate(source)
        let name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        guard !entries.contains(where: { $0.name == name || $0.source == source }) else {
            throw Self.invalid("This script is already imported. Remove its saved copy before importing a replacement.")
        }
        try save(entries + [Entry(id: UUID(), name: name, source: source, runAtStart: metadata.atStart, isEnabled: false)])
    }

    func setEnabled(_ enabled: Bool, for id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].isEnabled = enabled
        try save(updated)
    }

    func remove(id: UUID) throws { try save(entries.filter { $0.id != id }) }

    func apply(to controller: WKUserContentController) {
        let builtIn = controller.userScripts.filter { script in !installedScripts.contains { $0 === script } }
        installedScripts = entries.filter(\.isEnabled).map { entry in
            WKUserScript(source: """
            (() => {
                if (location.origin !== 'https://music.youtube.com') return;
                try {
                    (function () {
                        \(entry.source)
                    })();
                } catch (_) { console.error('Music: a custom script failed.'); }
            })();
            """, injectionTime: entry.runAtStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: true, in: .world(name: "MusicCustomScripts"))
        }
        controller.removeAllUserScripts()
        (builtIn + installedScripts).forEach(controller.addUserScript)
    }

    private func save(_ updated: [Entry]) throws {
        if let loadError { throw loadError }
        let data = try PropertyListEncoder().encode(updated)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        entries = updated
        onChange?()
    }

    private static func validate(_ source: String) throws -> (name: String?, atStart: Bool) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= 1_048_576 else { throw invalid("Choose a nonempty JavaScript file no larger than 1 MB.") }
        var name: String?
        var atStart = false
        if let start = source.range(of: "// ==UserScript==") {
            guard let end = source.range(of: "// ==/UserScript==", range: start.upperBound..<source.endIndex) else {
                throw invalid("The userscript metadata block is incomplete.")
            }
            for line in source[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
                let comment = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard comment.hasPrefix("//") else { continue }
                let directive = comment.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                guard directive.hasPrefix("@") else { continue }
                let parts = directive.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                let key = String(parts[0].dropFirst())
                let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                switch key {
                case "name": if !value.isEmpty { name = value }
                case "grant":
                    guard value == "none" else { throw invalid("This script requests privileged userscript APIs that Music doesn’t support.") }
                case "match":
                    guard ["https://music.youtube.com/*", "*://music.youtube.com/*"].contains(value) else {
                        throw invalid("Only @match https://music.youtube.com/* is supported. Scripts run only on YouTube Music.")
                    }
                case "run-at":
                    guard ["document-start", "document-end"].contains(value) else {
                        throw invalid("Music supports @run-at document-start and document-end.")
                    }
                    atStart = value == "document-start"
                case "description", "version", "author", "namespace", "license", "homepageURL", "supportURL", "icon", "noframes": break
                default: throw invalid("Music doesn’t support @\(key.prefix(40)). Import standalone JavaScript without external dependencies or userscript APIs.")
                }
            }
        }
        guard let context = JSContext() else { throw invalid("Couldn’t validate this script. Try importing it again.") }
        let literal = String(data: try JSONSerialization.data(withJSONObject: [source]), encoding: .utf8)!
        context.evaluateScript("new Function(\(literal)[0])")
        guard context.exception == nil else { throw invalid("This file contains invalid JavaScript. Check its syntax before importing it.") }
        return (name, atStart)
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "MusicScripts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
