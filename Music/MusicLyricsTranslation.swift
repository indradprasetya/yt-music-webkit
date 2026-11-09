import AppKit
import NaturalLanguage
import SwiftUI
import Translation

@MainActor
final class MusicLyricsTranslation: ObservableObject {
    @Published private var configuration: TranslationSession.Configuration?
    @Published private var batchID = UUID()
    private let defaults: UserDefaults
    private weak var host: NSView?
    private var current: Request?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var activeSession: TranslationSession?
    private var cache: [String: String] = [:]

    struct Batch {
        let source: String
        let indices: [Int]
    }

    private final class Request {
        let texts: [String]
        let target: String
        let reply: (Any?, String?) -> Void
        let onStatus: (String) -> Void
        private var phase = ""
        var batches: [Batch] = []
        var position = 0
        var result: [String]
        var message = ""

        init(texts: [String], target: String, onStatus: @escaping (String) -> Void, reply: @escaping (Any?, String?) -> Void) {
            self.texts = texts
            self.target = target
            self.reply = reply
            self.onStatus = onStatus
            result = Array(repeating: "", count: texts.count)
        }

        func report(_ value: String) {
            guard phase != value else { return }
            phase = value
            onStatus(value)
        }
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    private static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    var preferences: [String: Any] {
        ["target": defaults.string(forKey: "MusicLyricsTranslationLanguage") ?? ""]
    }

    func attach(to view: NSView) {
        guard host == nil else { return }
        let hosting = NSHostingView(rootView: TranslationView(model: self))
        hosting.frame = NSRect(x: max(0, view.bounds.width - 80), y: max(0, view.bounds.height - 140), width: 1, height: 1)
        hosting.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(hosting)
        host = hosting
    }

    func cancel() {
        guard let request = current else { return }
        finish(request, value: ["status": "cancelled"])
    }

    private func finish(_ request: Request, value: [String: Any]) {
        guard current === request else { return }
        current = nil
        configuration = nil
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        if #available(macOS 26.0, *) { activeSession?.cancel() }
        activeSession = nil
        if cache.count > 512 { cache.removeAll() }
        request.reply(value, nil)
    }

    func handle(_ body: [String: Any], onStatus: @escaping (String) -> Void = { _ in }, replyHandler: @escaping (Any?, String?) -> Void) {
        let action = body["action"] as? String
        if action == "cancel" { cancel(); replyHandler(["status": "cancelled"], nil); return }
        if action == "settings" {
            let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation")!
            if NSWorkspace.shared.open(url) { replyHandler(["status": "opened"], nil) }
            else { replyHandler(nil, "Open System Settings → General → Language & Region → Translation Languages.") }
            return
        }
        if action == "options" || action == "preferences" {
            Task {
                let supported = await Self.availability().supportedLanguages
                let codes = supported.map(\.minimalIdentifier)
                if action == "preferences" {
                    guard let target = body["target"] as? String, codes.contains(target) else {
                        replyHandler(nil, "Invalid lyric language preferences.")
                        return
                    }
                    defaults.set(target, forKey: "MusicLyricsTranslationLanguage")
                }
                let saved = preferences["target"] as? String ?? ""
                let preferred = [saved] + Locale.preferredLanguages
                let target = preferred.compactMap { identifier in
                    supported.first { $0.minimalIdentifier == identifier }
                        ?? supported.first { $0.languageCode == Locale.Language(identifier: identifier).languageCode
                            && $0.script == Locale.Language(identifier: identifier).script }
                }.first ?? supported.first { $0.languageCode?.identifier == "en" } ?? supported.first
                let options = codes.map { ["code": $0, "name": Locale.current.localizedString(forIdentifier: $0) ?? $0] }
                    .sorted { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
                replyHandler(["languages": options, "target": target?.minimalIdentifier ?? "en"], nil)
            }
            return
        }
        guard let input = body["texts"] as? [String], !input.isEmpty, input.count <= 5_000,
              input.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_192 }),
              input.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else {
            replyHandler(nil, "The lyrics are too large or invalid.")
            return
        }
        if action == "pronunciation" {
            let words = body["words"] as? [[[String: Any]]] ?? Array(repeating: [], count: input.count)
            let preferred = body["pronunciations"] as? [String] ?? Array(repeating: "", count: input.count)
            guard words.count == input.count, preferred.count == input.count,
                  words.allSatisfy({ $0.count <= 2_000 }), words.reduce(0, { $0 + $1.count }) <= 50_000,
                  preferred.allSatisfy({ $0.utf8.count <= 8_192 }),
                  preferred.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else {
                replyHandler(nil, "The pronunciation data is too large or invalid.")
                return
            }
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    input.indices.map { Self.pronunciationLine(input[$0], words: words[$0], preferred: preferred[$0]) }
                }.value
                replyHandler(["lines": result], nil)
            }
            return
        }
        guard action == "translate", let target = body["target"] as? String,
              target.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$"#, options: .regularExpression) != nil else {
            replyHandler(nil, "Invalid translation language.")
            return
        }
        cancel()
        let request = Request(texts: input, target: target, onStatus: onStatus, reply: replyHandler)
        current = request
        request.report("checking")
        task = Task {
            let supported = await Self.availability().supportedLanguages
            guard current === request else { return }
            guard supported.contains(where: { $0.minimalIdentifier == target }) else {
                request.message = "This language is not supported on this Mac."
                finish(request, value: ["status": "complete", "texts": request.result, "message": request.message])
                return
            }
            var seen: Set<String> = []
            request.batches = Self.batches(input, target: target).compactMap { batch in
                let indices = batch.indices.filter { index in
                    let key = target + "\0" + input[index]
                    if let cached = cache[key] { request.result[index] = cached; return false }
                    return seen.insert(input[index]).inserted
                }
                return indices.isEmpty ? nil : Batch(source: batch.source, indices: indices)
            }
            armTimeout(request, seconds: 60)
            await advance(request)
        }
    }

    nonisolated static func batches(_ texts: [String], target: String) -> [Batch] {
        let latin = texts.filter { $0.range(of: #"[^\p{Latin}\p{Common}\p{Inherited}]"#, options: .regularExpression) == nil }
        let songLanguage = NLLanguageRecognizer.dominantLanguage(for: texts.joined(separator: "\n"))?.rawValue ?? "en"
        let latinLanguage = NLLanguageRecognizer.dominantLanguage(for: latin.joined(separator: "\n"))?.rawValue ?? songLanguage
        let groups = Dictionary(grouping: texts.indices) { index -> String in
            let text = texts[index]
            if text.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil { return "ja" }
            if text.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil { return "ko" }
            if text.range(of: #"\p{Han}"#, options: .regularExpression) != nil { return songLanguage == "ja" ? "ja" : "zh-Hans" }
            // Short Latin lines are ambiguous on their own; identify them using the whole song.
            if text.range(of: #"[^\p{Latin}\p{Common}\p{Inherited}]"#, options: .regularExpression) == nil { return latinLanguage }
            return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? songLanguage
        }
        let targetCode = Locale.Language(identifier: target).languageCode
        return groups.sorted { $0.value[0] < $1.value[0] }.flatMap { source, indices -> [Batch] in
            guard Locale.Language(identifier: source).languageCode != targetCode else { return [] }
            return stride(from: 0, to: indices.count, by: 16).map {
                Batch(source: source, indices: Array(indices[$0..<min($0 + 16, indices.count)]))
            }
        }
    }

    private func armTimeout(_ request: Request, seconds: Int) {
        watchdog?.cancel()
        watchdog = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard current === request else { return }
            finish(request, value: ["status": "complete", "texts": request.result,
                "message": "Translation took too long. Try again, or check downloaded languages in System Settings."])
        }
    }

    private func advance(_ request: Request) async {
        while current === request && request.position < request.batches.count {
            let batch = request.batches[request.position]
            let source = Locale.Language(identifier: batch.source)
            let target = Locale.Language(identifier: request.target)
            let status = await Self.availability().status(from: source, to: target)
            guard current === request else { return }
            if status == .unsupported {
                request.message = "Some lines use a language pair not supported on this Mac."
                request.position += 1
                continue
            }
            let token = UUID()
            batchID = token
            if status == .installed, #available(macOS 26.0, *) {
                request.report("translating")
                // Installed models need no permission UI on recent macOS versions.
                let session: TranslationSession
                if #available(macOS 26.4, *) {
                    session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                } else { session = TranslationSession(installedSource: source, target: target) }
                task = Task { await execute(session, token: token) }
            } else if host != nil {
                request.report(status == .supported ? "download" : "translating")
                if status == .supported { armTimeout(request, seconds: 180) }
                var next: TranslationSession.Configuration
                if #available(macOS 26.4, *) {
                    next = TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
                } else { next = TranslationSession.Configuration(source: source, target: target) }
                next.invalidate()
                configuration = next
            } else {
                request.message = "Open the Music window to download the required translation languages."
                request.position += 1
                continue
            }
            return
        }
        guard current === request else { return }
        finish(request, value: ["status": "complete", "texts": request.result, "message": request.message])
    }

    private func execute(_ session: TranslationSession, token: UUID) async {
        guard token == batchID, let request = current, request.position < request.batches.count else { return }
        activeSession = session
        let batch = request.batches[request.position]
        do {
            let requests = batch.indices.map { TranslationSession.Request(sourceText: request.texts[$0], clientIdentifier: String($0)) }
            for try await response in session.translate(batch: requests) {
                guard current === request, token == batchID else { return }
                request.report("translating")
                guard let index = response.clientIdentifier.flatMap(Int.init), request.texts.indices.contains(index) else { continue }
                let original = request.texts[index]
                let translated = response.targetText == original ? "" : response.targetText
                cache[request.target + "\0" + original] = translated
                for position in request.texts.indices where request.texts[position] == original { request.result[position] = translated }
            }
        } catch {
            guard current === request, token == batchID else { return }
            request.message = "Some lines could not be translated. Check downloaded languages and try again."
        }
        guard current === request, token == batchID else { return }
        activeSession = nil
        request.position += 1
        await advance(request)
    }

    private struct TranslationView: View {
        @ObservedObject var model: MusicLyricsTranslation
        var body: some View {
            let token = model.batchID
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
                .translationTask(model.configuration) { await model.execute($0, token: token) }
        }
    }

    nonisolated static func pronunciationLine(_ text: String, words: [[String: Any]], preferred: String = "") -> [String: Any] {
        let language = NLLanguageRecognizer.dominantLanguage(for: text)
        let pronunciation = preferred.isEmpty ? romanize(text, language: language) ?? "" : preferred
        let plain: [String: Any] = ["text": pronunciation, "words": [] as [[String: Any]]]
        guard !pronunciation.isEmpty, !words.isEmpty,
              words.compactMap({ $0["word"] as? String }).joined().trimmingCharacters(in: .whitespacesAndNewlines) == text else { return plain }
        func normalized(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        var segments: [(text: String, start: Any, end: Any)] = []
        var previous = -1.0
        for word in words {
            guard let original = word["word"] as? String,
                  let start = word["start_time"] as? NSNumber, let end = word["end_time"] as? NSNumber,
                  CFGetTypeID(start) != CFBooleanGetTypeID(), CFGetTypeID(end) != CFBooleanGetTypeID(),
                  start.doubleValue.isFinite, end.doubleValue.isFinite,
                  start.doubleValue >= max(0, previous), end.doubleValue > start.doubleValue, end.doubleValue <= 3_602_000 else { return plain }
            previous = start.doubleValue
            let value = romanize(original, language: language) ?? original
            if !normalized(value).isEmpty { segments.append((value, word["start_time"]!, word["end_time"]!)) }
        }
        guard !segments.isEmpty, segments.map({ normalized($0.text) }).joined() == normalized(pronunciation) else { return plain }
        let characters = Array(pronunciation)
        var position = 0
        var timed: [[String: Any]] = []
        for segment in segments {
            let begin = position
            let count = normalized(segment.text).count
            var consumed = 0
            while position < characters.count && consumed < count {
                consumed += normalized(String(characters[position])).count
                position += 1
            }
            guard consumed == count else { return plain }
            while position < characters.count && normalized(String(characters[position])).isEmpty { position += 1 }
            timed.append(["word": String(characters[begin..<position]), "start_time": segment.start, "end_time": segment.end])
        }
        guard position == characters.count else { return plain }
        return ["text": pronunciation, "words": timed]
    }

    nonisolated static func romanize(_ text: String, language hint: NLLanguage? = nil) -> String? {
        guard text.range(of: #"[^\p{Latin}\p{Common}\p{Inherited}]"#, options: .regularExpression) != nil else { return nil }
        let language = hint ?? NLLanguageRecognizer.dominantLanguage(for: text)
        var result = ""
        if language == .japanese {
            let string = text as CFString
            let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)!
            var previous = 0
            while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let original = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
                if range.location > previous { result += (text as NSString).substring(with: NSRange(location: previous, length: range.location - previous)) }
                let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                if !result.isEmpty, !result.hasSuffix(" "), latin != nil { result += " " }
                result += latin ?? original
                previous = range.location + range.length
            }
            if previous < (text as NSString).length { result += (text as NSString).substring(from: previous) }
        } else {
            result = text.applyingTransform(.toLatin, reverse: false) ?? ""
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != text,
              result.range(of: #"[^\p{Latin}\p{Common}\p{Inherited}]"#, options: .regularExpression) == nil else { return nil }
        // shortcut: automatic romanization cannot infer unusual sung readings; prefer provider pronunciation.
        return result
    }

}
