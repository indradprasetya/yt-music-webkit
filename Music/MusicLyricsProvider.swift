// SPDX-License-Identifier: MIT
// Provider request flow adapted from syncedlyrics, Copyright (c) 2022 Momo.
// Upstream: moehmeni/syncedlyrics @ 3c8a318d9a8df26855bdc3a5d23f7fd2b99ade2e
// Full MIT license and modification notice: THIRD_PARTY_NOTICES.txt.
import Foundation
import Yams

private struct LRCLIBLyricsFile: Decodable {
    struct Metadata: Decodable {
        let title: String
        let artist: String
        let durationMS: Int?

        enum CodingKeys: String, CodingKey {
            case title, artist
            case durationMS = "duration_ms"
        }
    }

    struct Word: Decodable {
        let text: String
        let startMS: Int
        let endMS: Int?

        enum CodingKeys: String, CodingKey {
            case text
            case startMS = "start_ms"
            case endMS = "end_ms"
        }
    }

    struct Line: Decodable {
        let text: String
        let startMS: Int
        let endMS: Int?
        let words: [Word]?

        enum CodingKeys: String, CodingKey {
            case text, words
            case startMS = "start_ms"
            case endMS = "end_ms"
        }
    }

    let version: String
    let metadata: Metadata
    let lines: [Line]?
    let plain: String?
}

@MainActor
final class MusicLyricsProvider {
    struct Track {
        let title: String
        let artist: String
        let album: String
        let duration: Double

        init?(_ body: Any) {
            guard let body = body as? [String: Any],
                  let title = body["title"] as? String, let artist = body["artist"] as? String,
                  let duration = body["duration"] as? Double,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf8.count <= 500, artist.utf8.count <= 500,
                  duration.isFinite, (1...3600).contains(duration) else { return nil }
            self.title = title
            self.artist = artist
            let album = body["album"] as? String ?? ""
            guard album.utf8.count <= 500 else { return nil }
            self.album = album
            self.duration = duration
        }
    }

    struct Record {
        let source: String
        let synced: String
        let plain: String
        let yrc: String
        let lyricsFileLines: [[String: Any]]
        let synchronized: Bool

        init(source: String, synced: String, plain: String, yrc: String = "",
             lyricsFileLines: [[String: Any]] = [], synchronized: Bool) {
            self.source = source
            self.synced = synced
            self.plain = plain
            self.yrc = yrc
            self.lyricsFileLines = lyricsFileLines
            self.synchronized = synchronized
        }

        var timingQuality: Int {
            guard synchronized else { return 0 }
            if lyricsFileLines.contains(where: { ($0["words"] as? [[String: Any]])?.isEmpty == false })
                || yrc.range(of: #"\(\d+,\d+,\d+\)"#, options: .regularExpression) != nil { return 2 }
            if !lyricsFileLines.isEmpty
                || synced.range(of: #"\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil { return 1 }
            return 0
        }

        var dictionary: [String: Any] {
            var dict: [String: Any] = [
                "source": source,
                "syncedLyrics": synced,
                "plainLyrics": plain,
                "synchronized": synchronized
            ]
            if !yrc.isEmpty {
                dict["yrcLyrics"] = yrc
            }
            if !lyricsFileLines.isEmpty {
                dict["lyricsFileLines"] = lyricsFileLines
            }
            return dict
        }
    }

    struct Lookup {
        let record: Record?
        let message: String?
        let retryAfter: TimeInterval
        var alternatives: [Record] = []

        var dictionary: [String: Any] {
            if let record {
                return ["status": "found", "record": record.dictionary,
                        "alternatives": alternatives.map(\.dictionary)]
            }
            return ["status": message == nil ? "notFound" : "unavailable",
                    "message": message ?? "No matching lyrics.", "retryAfter": retryAfter]
        }
    }

    private enum Failure: Error {
        case http(Int), invalidData, rejected(Int)
    }

    private let session: URLSession
    private var lastRequest: [String: Date] = [:]
    private var cooldown: [String: Date] = [:]

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
        configuration.httpAdditionalHeaders = ["User-Agent": "Music/\(version) (https://github.com/indradprasetya/yt-music-webkit)"]
        self.session = session ?? URLSession(configuration: configuration)
    }

    func lookup(_ track: Track) async throws -> Lookup {
        var failures: [String] = []
        var best: Record?
        var alternatives: [Record] = []
        var matchedNetEaseIDs: Set<String> = []
        for source in ["NetEase", "LRCLIB", "AMLL", "Better Lyrics", "lrcmux"] {
            try Task.checkCancellation()
            if let until = cooldown[source], until > Date() {
                failures.append("\(source) is busy.")
                continue
            }
            do {
                let deadline = Date(timeIntervalSinceNow: ["NetEase", "LRCLIB"].contains(source) ? 10 : 6)
                let records: [Record]
                if source == "NetEase" {
                    let matches = try await netEaseMatches(track, deadline: deadline)
                    matchedNetEaseIDs = Set(matches.filter { abs($0.duration - track.duration) <= 2 }.map { String($0.id) })
                    let record = try await netEase(track, matches: matches, deadline: deadline)
                    records = record.map { [$0] } ?? []
                } else if source == "LRCLIB" {
                    records = try await lrcLib(track, deadline: deadline)
                } else if source == "AMLL" {
                    records = try await amll(track, matchedNetEaseIDs: matchedNetEaseIDs, deadline: deadline)
                } else if source == "Better Lyrics" {
                    records = try await betterLyrics(track, deadline: deadline)
                } else {
                    records = try await lrcmux(track, deadline: deadline)
                }
                try Task.checkCancellation()
                for record in records {
                    if let index = alternatives.firstIndex(where: { $0.source == record.source }) {
                        if record.timingQuality > alternatives[index].timingQuality { alternatives[index] = record }
                    } else {
                        alternatives.append(record)
                    }
                    if let current = best {
                        if record.timingQuality > current.timingQuality { best = record }
                    } else {
                        best = record
                    }
                }
            } catch {
                try Task.checkCancellation()
                if let error = error as? URLError {
                    if error.code == .cancelled { throw CancellationError() }
                    failures.append(error.code == .timedOut ? "\(source) took too long." : "Couldn’t reach \(source).")
                } else if let failure = error as? Failure {
                    switch failure {
                    case .http(let status): failures.append(status == 503
                        ? "\(source) is temporarily unavailable." : "\(source) returned HTTP \(status).")
                    case .rejected(let code): failures.append("\(source) declined the request (\(code)).")
                    case .invalidData: failures.append("\(source) returned unreadable data.")
                    }
                } else {
                    failures.append("\(source) returned unreadable data.")
                }
            }
        }
        if let best { return Lookup(record: best, message: nil, retryAfter: 0, alternatives: alternatives) }
        let remaining = cooldown.values.map { max(0, $0.timeIntervalSinceNow) }.max() ?? 0
        return Lookup(record: nil, message: failures.isEmpty ? nil : failures.joined(separator: " "), retryAfter: remaining)
    }

    private func request(_ endpoint: String, query: [URLQueryItem], source: String, deadline: Date,
                         retryUnavailable: Bool = true) async throws -> Any? {
        if let previous = lastRequest[source] {
            let delay = (source == "lrcmux" ? 1 : 0.35) - Date().timeIntervalSince(previous)
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        try Task.checkCancellation()
        guard deadline > Date() else { throw URLError(.timedOut) }
        var components = URLComponents(string: endpoint)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = max(0.1, deadline.timeIntervalSinceNow)
        lastRequest[source] = Date()
        let remaining = deadline.timeIntervalSinceNow
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [session, request] in try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, remaining)))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidData }
        // Anonymous Better Lyrics returns 401 for an uncached query, not an account login request.
        if response.statusCode == 404 || (source == "Better Lyrics" && response.statusCode == 401) { return nil }
        if response.statusCode == 429 || response.statusCode == 503 {
            let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let seconds = Double(value) ?? formatter.date(from: value)?.timeIntervalSinceNow
                ?? (response.statusCode == 429 ? 60 : 1)
            cooldown[source] = Date(timeIntervalSinceNow: max(1, seconds) * Double.random(in: 1...1.3))
        }
        if response.statusCode == 503, retryUnavailable, let until = cooldown[source], until < deadline {
            try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            return try await self.request(endpoint, query: query, source: source, deadline: deadline,
                                          retryUnavailable: false)
        }
        guard (200...299).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        cooldown.removeValue(forKey: source)
        guard data.count <= 2_097_152 else { throw Failure.invalidData }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func netEaseMatches(_ track: Track, deadline: Date) async throws -> [(id: Int, duration: Double)] {
        guard let data = try await request("https://music.163.com/api/cloudsearch/pc", query: [
            URLQueryItem(name: "s", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "offset", value: "0")
        ], source: "NetEase", deadline: deadline) as? [String: Any] else { throw Failure.invalidData }
        guard let code = data["code"] as? Int else { throw Failure.invalidData }
        guard code == 200 else { throw Failure.rejected(code) }
        let songs = (data["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap { song -> (id: Int, duration: Double)? in
            let artists = (song["ar"] ?? song["artists"]) as? [[String: Any]] ?? []
            guard normalize(song["name"] as? String) == normalize(track.title),
                  artists.contains(where: { normalize($0["name"] as? String) == normalize(track.artist) }),
                  let id = song["id"] as? Int,
                  let duration = (song["dt"] ?? song["duration"]) as? Double,
                  duration.isFinite, abs(duration / 1000 - track.duration) <= 15 else { return nil }
            return (id, duration / 1000)
        }.sorted { abs($0.duration - track.duration) < abs($1.duration - track.duration) }
    }

    private func netEase(_ track: Track, matches: [(id: Int, duration: Double)], deadline: Date) async throws -> Record? {
        var best: Record?
        var lastError: Error?
        func vocalText(_ value: String) -> String {
            // NetEase can return only JSON credit rows without any song lyrics.
            value.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }.joined(separator: "\n")
        }
        for match in matches {
            try Task.checkCancellation()
            if Date() >= deadline || (cooldown["NetEase"].map { $0 > Date() } ?? false) { break }
            // Other versions cannot improve timing once their duration differs too much.
            if best != nil && abs(match.duration - track.duration) > 2 { break }
            do {
                guard let response = try await request("https://music.163.com/api/song/lyric/v1", query: [
                    URLQueryItem(name: "id", value: String(match.id)),
                    URLQueryItem(name: "cp", value: "false"),
                    URLQueryItem(name: "lv", value: "0"), URLQueryItem(name: "tv", value: "0"),
                    URLQueryItem(name: "rv", value: "0"), URLQueryItem(name: "kv", value: "0"),
                    URLQueryItem(name: "yv", value: "0"), URLQueryItem(name: "ytv", value: "0"),
                    URLQueryItem(name: "yrv", value: "0")
                ], source: "NetEase", deadline: deadline) as? [String: Any] else { throw Failure.invalidData }
                guard let code = response["code"] as? Int else { throw Failure.invalidData }
                guard code == 200 else { throw Failure.rejected(code) }
                let yrc = (response["yrc"] as? [String: Any])?["lyric"] as? String ?? ""
                let synced = (response["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
                let yrcText = vocalText(yrc)
                let lrcText = vocalText(synced)
                let plain = lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? yrcText : lrcText
                guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let hasYRC = validYRC(yrcText, duration: track.duration)
                let hasLRC = lrcText.range(of: #"\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
                let hasTimestamps = hasYRC || hasLRC
                let record = Record(source: "NetEase", synced: hasLRC ? synced : "",
                                    plain: hasTimestamps ? "" : plain,
                                    yrc: hasYRC ? yrc : "",
                                    synchronized: hasTimestamps && abs(match.duration - track.duration) <= 2)
                if best == nil || record.timingQuality > best!.timingQuality { best = record }
                if record.timingQuality == 2 { break }
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if let best { return best }
        if let lastError { throw lastError }
        return nil
    }

    private func validYRC(_ value: String, duration: Double) -> Bool {
        let limit = Int((duration + 2) * 1000)
        let header = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let token = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)
        let rows = value.split(whereSeparator: \.isNewline)
        guard !rows.isEmpty, rows.count <= 5_000 else { return false }
        for row in rows {
            let text = String(row).trimmingCharacters(in: .whitespaces) as NSString
            guard let line = header.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
                  let start = Int(text.substring(with: line.range(at: 1))),
                  let length = Int(text.substring(with: line.range(at: 2))),
                  length > 0, length <= limit, start <= limit - length else { return false }
            let body = text.substring(from: NSMaxRange(line.range)) as NSString
            let words = token.matches(in: body as String, range: NSRange(location: 0, length: body.length))
            guard !words.isEmpty, words.count <= 2_000 else { return false }
            var previous = start
            var position = 0
            var hasText = false
            for word in words {
                guard word.range.location == position,
                      let begin = Int(body.substring(with: word.range(at: 1))),
                      let span = Int(body.substring(with: word.range(at: 2))),
                      begin >= previous, span > 0, span <= length,
                      begin <= start + length - span else { return false }
                hasText = hasText || !body.substring(with: word.range(at: 3)).trimmingCharacters(in: .whitespaces).isEmpty
                previous = begin
                position = NSMaxRange(word.range)
            }
            guard position == body.length, hasText else { return false }
        }
        return true
    }

    private func lrcLib(_ track: Track, deadline: Date) async throws -> [Record] {
        guard let response = try await request("https://lrclib.net/api/search", query: [
            URLQueryItem(name: "q", value: "\(track.title) \(track.artist)")
        ], source: "LRCLIB", deadline: deadline) else { return [] }
        guard let records = response as? [[String: Any]] else { throw Failure.invalidData }
        let matches = records.filter { record in
            guard normalize(record["trackName"] as? String) == normalize(track.title),
                  normalize(record["artistName"] as? String) == normalize(track.artist),
                  let duration = record["duration"] as? Double, duration.isFinite else { return false }
            return abs(duration - track.duration) <= 15 && record["instrumental"] as? Bool != true
        }.sorted { abs(($0["duration"] as! Double) - track.duration) < abs(($1["duration"] as! Double) - track.duration) }
        return matches.compactMap { match in
            let synced = match["syncedLyrics"] as? String ?? ""
            let parsed = parseLyricsFile(match["lyricsfile"] as? String, track: track)
            let legacyPlain = match["plainLyrics"] as? String ?? ""
            let plain = legacyPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? parsed.plain : legacyPlain
            if synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               parsed.lines.isEmpty { return nil }
            return Record(source: "LRCLIB", synced: synced, plain: plain,
                          lyricsFileLines: parsed.lines,
                          synchronized: abs((match["duration"] as! Double) - track.duration) <= 2)
        }
    }

    private func amll(_ track: Track, matchedNetEaseIDs: Set<String>, deadline: Date) async throws -> [Record] {
        guard let response = try await request("https://api.amll.dev/v1/lyrics/search", query: [
            URLQueryItem(name: "musicName", value: track.title),
            URLQueryItem(name: "artistName", value: track.artist),
            URLQueryItem(name: "pageSize", value: "10")
        ], source: "AMLL", deadline: deadline) else { return [] }
        guard let response = response as? [String: Any], response["status"] as? Int == 200,
              let data = response["data"] as? [String: Any],
              let items = data["items"] as? [[String: Any]] else { throw Failure.invalidData }
        func matches(_ item: [String: Any]) -> Bool {
            (item["musicNames"] as? [String] ?? []).contains { normalize($0) == normalize(track.title) }
                && (item["artistNames"] as? [String] ?? []).contains { normalize($0) == normalize(track.artist) }
        }
        func verified(_ item: [String: Any]) -> Bool {
            !matchedNetEaseIDs.isDisjoint(with: item["ncmMusicIds"] as? [String] ?? [])
        }
        let candidates = items.prefix(10).filter(matches).sorted { verified($0) && !verified($1) }
        var records: [Record] = []
        var lastError: Error?
        for candidate in candidates.prefix(3) {
            try Task.checkCancellation()
            if Date() >= deadline || (cooldown["AMLL"].map { $0 > Date() } ?? false) { break }
            guard let id = candidate["id"] as? Int, id > 0, id <= 9_007_199_254_740_991 else { continue }
            do {
                guard let result = try await request("https://api.amll.dev/v1/lyrics/get", query: [
                    URLQueryItem(name: "id", value: String(id))
                ], source: "AMLL", deadline: deadline) else { continue }
                guard let result = result as? [String: Any], result["status"] as? Int == 200,
                      let song = result["data"] as? [String: Any], song["id"] as? Int == id,
                      matches(song), song["format"] as? String == "ttml",
                      let xml = song["lyrics"] as? String,
                      let parsed = MusicTTML.parse(xml, duration: track.duration) else { throw Failure.invalidData }
                // Platform IDs associate versions; the API does not expose original-provider provenance.
                let record = Record(source: "AMLL", synced: "", plain: parsed.plain,
                                    lyricsFileLines: parsed.lines,
                                    synchronized: verified(song) && !parsed.lines.isEmpty)
                records.append(record)
                if record.timingQuality == 2 { break }
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if records.isEmpty, let lastError { throw lastError }
        return records
    }

    private func betterLyrics(_ track: Track, deadline: Date) async throws -> [Record] {
        guard let response = try await request("https://api.betterlyrics.org/getLyrics", query: [
            URLQueryItem(name: "s", value: track.title), URLQueryItem(name: "a", value: track.artist),
            URLQueryItem(name: "al", value: track.album),
            URLQueryItem(name: "d", value: String(Int(track.duration.rounded())))
        ], source: "Better Lyrics", deadline: deadline) else { return [] }
        guard let data = response as? [String: Any], let xml = data["ttml"] as? String,
              let parsed = MusicTTML.parse(xml, duration: track.duration) else { throw Failure.invalidData }
        guard !parsed.lines.isEmpty else { return [] }
        return [Record(source: "Better Lyrics", synced: "", plain: parsed.plain,
                       lyricsFileLines: parsed.lines, synchronized: true)]
    }

    private func lrcmux(_ track: Track, deadline: Date) async throws -> [Record] {
        guard let response = try await request("https://api.lrcmux.dev/get", query: [
            URLQueryItem(name: "title", value: track.title), URLQueryItem(name: "artist", value: track.artist),
            URLQueryItem(name: "album", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
            URLQueryItem(name: "level", value: "word"), URLQueryItem(name: "format", value: "json")
        ], source: "lrcmux", deadline: deadline) else { return [] }
        guard let data = response as? [String: Any], let song = data["track"] as? [String: Any],
              let meta = data["meta"] as? [String: Any], let level = meta["level"] as? String,
              let rawLines = data["lines"] as? [[String: Any]], rawLines.count <= 5_000 else { throw Failure.invalidData }
        guard normalize(song["title"] as? String) == normalize(track.title),
              normalize(song["artist"] as? String) == normalize(track.artist),
              let duration = song["duration"] as? Double, duration.isFinite,
              abs(duration - track.duration) <= 2, ["word", "line"].contains(level) else { return [] }
        let limit = Int((track.duration + 2) * 1000)
        var lines: [[String: Any]] = []
        for line in rawLines {
            guard let text = line["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = line["start"] as? Int, (0...limit).contains(start) else { continue }
            let end = line["end"] as? Int ?? limit
            guard end >= start, end <= limit else { continue }
            var words: [[String: Any]] = []
            if level == "word", let rawWords = line["words"] as? [[String: Any]], rawWords.count <= 2_000 {
                var previous = start
                for word in rawWords {
                    guard let value = word["text"] as? String, !value.isEmpty,
                          let begin = word["start"] as? Int, let finish = word["end"] as? Int,
                          begin >= previous, finish > begin, finish <= end else { words = []; break }
                    previous = begin
                    words.append(["word": value, "start_time": begin, "end_time": finish])
                }
                if words.compactMap({ $0["word"] as? String }).joined() != text { words = [] }
            }
            lines.append(["time": start, "text": text, "words": words, "credit": false])
        }
        guard !lines.isEmpty else { return [] }
        lines.sort { ($0["time"] as! Int) < ($1["time"] as! Int) }
        let origin = meta["source"] as? [String: Any]
        let provider = ["deezer": "Deezer", "kugou": "KuGou", "ytmusic": "YouTube Music",
                        "genius": "Genius", "musixmatch": "Musixmatch"][origin?["id"] as? String ?? ""]
        return [Record(source: provider.map { "lrcmux (\($0))" } ?? "lrcmux", synced: "", plain: "",
                       lyricsFileLines: lines, synchronized: true)]
    }

    private func parseLyricsFile(_ yaml: String?, track: Track) -> (lines: [[String: Any]], plain: String) {
        guard let yaml, yaml.utf8.count <= 2_097_152,
              let file = try? YAMLDecoder().decode(LRCLIBLyricsFile.self, from: yaml),
              file.version == "1.0",
              normalize(file.metadata.title) == normalize(track.title),
              normalize(file.metadata.artist) == normalize(track.artist),
              file.metadata.durationMS.map({ abs(Double($0) / 1000 - track.duration) <= 2 }) ?? true else {
            return ([], "")
        }

        let lines = (file.lines ?? []).sorted { $0.startMS < $1.startMS }
        guard lines.count <= 5_000 else { return ([], "") }
        let durationLimit = (track.duration + 2) * 1000
        let parsedLines = lines.enumerated().compactMap { index, line -> [String: Any]? in
            guard line.startMS >= 0, Double(line.startMS) <= durationLimit else { return nil }
            let nextLineStart = index + 1 < lines.count ? lines[index + 1].startMS : nil
            let lineEnd = line.endMS.flatMap { $0 > line.startMS ? $0 : nil }
                ?? nextLineStart.flatMap { $0 > line.startMS ? $0 : nil }
            var parsedWords: [[String: Any]] = []
            if let words = line.words, !words.isEmpty, words.count <= 2_000,
               words.map(\.text).joined() == line.text {
                var valid = true
                var previousWordStart = line.startMS
                for (wordIndex, word) in words.enumerated() {
                    let nextWordStart = wordIndex + 1 < words.count ? words[wordIndex + 1].startMS : nil
                    guard word.startMS >= previousWordStart, Double(word.startMS) <= durationLimit,
                          let end = word.endMS.flatMap({ $0 > word.startMS ? $0 : nil })
                            ?? nextWordStart.flatMap({ $0 > word.startMS ? $0 : nil })
                            ?? lineEnd,
                          end > word.startMS, Double(end) <= durationLimit else {
                        valid = false
                        break
                    }
                    previousWordStart = word.startMS
                    parsedWords.append(["word": word.text, "start_time": word.startMS, "end_time": end])
                }
                if !valid { parsedWords = [] }
            }
            return ["time": line.startMS, "text": line.text, "words": parsedWords, "credit": false]
        }
        return (parsedLines, file.plain ?? "")
    }

    private func normalize(_ value: String?) -> String {
        (value ?? "").precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
