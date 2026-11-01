import Foundation

final class MusicTTML: NSObject, XMLParserDelegate {
    private struct Word {
        var text = ""
        let start: Int
        let end: Int
    }

    private let limit: Int
    private var depth = 0
    private var elements = 0
    private var bodyDepth: Int?
    private var lineDepth: Int?
    private var skippedDepth: Int?
    private var wordDepth: Int?
    private var text = ""
    private var start: Int?
    private var end: Int?
    private var invalidLine = false
    private var invalidWords = false
    private var words: [Word] = []
    private var lines: [[String: Any]] = []
    private var plain: [String] = []

    private init(duration: Double) {
        limit = Int((duration + 2) * 1000)
    }

    static func parse(_ xml: String, duration: Double) -> (lines: [[String: Any]], plain: String)? {
        guard duration.isFinite, (1...3600).contains(duration), xml.utf8.count <= 2_097_152,
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        let delegate = MusicTTML(duration: duration)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.plain.isEmpty else { return nil }
        let lines = delegate.lines.count == delegate.plain.count
            ? delegate.lines.sorted { ($0["time"] as! Int) < ($1["time"] as! Int) } : []
        return (lines, delegate.plain.joined(separator: "\n"))
    }

    private func milliseconds(_ value: String?) -> Int? {
        guard let raw = value, raw.utf8.count <= 32 else { return nil }
        let value = raw.hasSuffix("s") && !raw.contains(":") ? String(raw.dropLast()) : raw
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            let pattern = index == parts.count - 1 ? #"^\d+(?:\.\d+)?$"# : #"^\d+$"#
            guard part.range(of: pattern, options: .regularExpression) != nil,
                  let number = Double(part), number.isFinite else { return nil }
            seconds = seconds * 60 + number
        }
        guard seconds.isFinite, seconds >= 0, seconds * 1000 <= Double(limit) else { return nil }
        return Int((seconds * 1000).rounded())
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        elements += 1
        guard depth <= 64, elements <= 100_000,
              depth != 1 || (name == "tt" && namespaceURI == "http://www.w3.org/ns/ttml") else {
            parser.abortParsing()
            return
        }
        if name == "body" { bodyDepth = depth }
        guard bodyDepth != nil, skippedDepth == nil else { return }
        let role = attributes.first { $0.key == "role" || $0.key.hasSuffix(":role") }?.value
        let ruby = attributes.first { $0.key == "ruby" || $0.key.hasSuffix(":ruby") }?.value
        // shortcut: the current renderer shows main vocals only; add separate auxiliary rows when supported.
        if ["x-translation", "x-roman", "x-bg"].contains(role ?? "")
            || ["text", "textContainer", "delimiter"].contains(ruby ?? "") || name == "rt" {
            skippedDepth = depth
            return
        }
        // AMLL p/span clocks are absolute, including inside a div with a nonzero begin.
        if attributes["timeContainer"] == "seq" {
            parser.abortParsing()
            return
        }
        if name == "p" {
            guard lineDepth == nil, plain.count < 5_000 else { parser.abortParsing(); return }
            lineDepth = depth
            text = ""
            words = []
            wordDepth = nil
            start = milliseconds(attributes["begin"])
            end = milliseconds(attributes["end"])
            invalidLine = (attributes["begin"] != nil && start == nil) || (attributes["end"] != nil && end == nil)
            invalidWords = false
        } else if lineDepth != nil, name == "span", wordDepth == nil,
                  attributes["begin"] != nil || attributes["end"] != nil {
            guard words.count < 2_000 else { parser.abortParsing(); return }
            if let begin = milliseconds(attributes["begin"]), let finish = milliseconds(attributes["end"]), finish > begin {
                words.append(Word(start: begin, end: finish))
                wordDepth = depth
            } else {
                invalidWords = true
            }
        } else if lineDepth != nil, name == "br" {
            append(" ")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard lineDepth != nil, skippedDepth == nil else { return }
        if string.contains("\n"), string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let string = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    private func append(_ string: String) {
        text += string
        if wordDepth == nil, !words.isEmpty, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            invalidWords = true
        }
        if !words.isEmpty { words[words.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if skippedDepth == depth { skippedDepth = nil; return }
        guard skippedDepth == nil else { return }
        if wordDepth == depth { wordDepth = nil }
        if lineDepth == depth {
            lineDepth = nil
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            plain.append(value)
            if !words.isEmpty {
                words[0].text = words[0].text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
                let last = words.count - 1
                words[last].text = words[last].text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            }
            guard !invalidLine, let begin = start ?? words.first?.start,
                  let finish = end ?? words.last?.end ?? start, finish >= begin else { return }
            var previous = begin
            let valid = !invalidWords && words.map(\.text).joined() == value && words.allSatisfy { word in
                defer { previous = word.start }
                return word.start >= previous && word.end <= finish
            }
            let timedWords: [[String: Any]] = valid ? words.map {
                ["word": $0.text, "start_time": $0.start, "end_time": $0.end]
            } : []
            lines.append(["time": begin, "text": value, "words": timedWords, "credit": false])
        }
        if bodyDepth == depth { bodyDepth = nil }
    }
}
