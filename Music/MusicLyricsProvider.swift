// SPDX-License-Identifier: MIT
// Provider request flow adapted from syncedlyrics, Copyright (c) 2022 Momo.
// Upstream: moehmeni/syncedlyrics @ 3c8a318d9a8df26855bdc3a5d23f7fd2b99ade2e
// Full MIT license and modification notice: THIRD_PARTY_NOTICES.txt.
import Foundation

@MainActor
final class MusicLyricsProvider {
    struct Track {
        let title: String
        let artist: String
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
            self.duration = duration
        }
    }

    struct Record {
        let source: String
        let synced: String
        let plain: String
        let synchronized: Bool

        var hasTiming: Bool {
            synchronized && synced.range(of: #"\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
        }

        var dictionary: [String: Any] {
            ["source": source, "syncedLyrics": synced, "plainLyrics": plain, "synchronized": synchronized]
        }
    }

    struct Lookup {
        let record: Record?
        let message: String?
        let retryAfter: TimeInterval

        var dictionary: [String: Any] {
            if let record { return ["status": "found", "record": record.dictionary] }
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
        var plain: Record?
        for source in ["NetEase", "LRCLIB"] {
            try Task.checkCancellation()
            if let until = cooldown[source], until > Date() {
                failures.append("\(source) is busy.")
                continue
            }
            do {
                let deadline = Date(timeIntervalSinceNow: 10)
                let record: Record?
                if source == "NetEase" { record = try await netEase(track, deadline: deadline) }
                else { record = try await lrcLib(track, deadline: deadline) }
                try Task.checkCancellation()
                if let record {
                    if record.hasTiming { return Lookup(record: record, message: nil, retryAfter: 0) }
                    if plain == nil { plain = record }
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
        if let plain { return Lookup(record: plain, message: nil, retryAfter: 0) }
        let remaining = cooldown.values.map { max(0, $0.timeIntervalSinceNow) }.max() ?? 0
        return Lookup(record: nil, message: failures.isEmpty ? nil : failures.joined(separator: " "), retryAfter: remaining)
    }

    private func request(_ endpoint: String, query: [URLQueryItem], source: String, deadline: Date,
                         retryUnavailable: Bool = true) async throws -> Any? {
        if let previous = lastRequest[source] {
            let delay = 0.35 - Date().timeIntervalSince(previous)
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
        if response.statusCode == 404 { return nil }
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
            return try await self.request(endpoint, query: query, source: source, deadline: deadline, retryUnavailable: false)
        }
        guard (200...299).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        cooldown.removeValue(forKey: source)
        guard data.count <= 2_097_152 else { throw Failure.invalidData }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func netEase(_ track: Track, deadline: Date) async throws -> Record? {
        guard let data = try await request("https://music.163.com/api/search/pc", query: [
            URLQueryItem(name: "s", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "offset", value: "0")
        ], source: "NetEase", deadline: deadline) as? [String: Any] else { throw Failure.invalidData }
        guard let code = data["code"] as? Int else { throw Failure.invalidData }
        guard code == 200 else { throw Failure.rejected(code) }
        let songs = (data["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        let matches = songs.filter { song in
            let artists = song["artists"] as? [[String: Any]] ?? []
            guard normalize(song["name"] as? String) == normalize(track.title),
                  artists.contains(where: { normalize($0["name"] as? String) == normalize(track.artist) }),
                  let duration = song["duration"] as? Double else { return false }
            return abs(duration / 1000 - track.duration) <= 15
        }.sorted { abs(($0["duration"] as! Double) / 1000 - track.duration)
            < abs(($1["duration"] as! Double) / 1000 - track.duration) }
        guard let match = matches.first, let id = match["id"] as? Int else { return nil }
        guard let response = try await request("https://music.163.com/api/song/lyric", query: [
            URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "lv", value: "1")
        ], source: "NetEase", deadline: deadline) as? [String: Any] else { throw Failure.invalidData }
        guard let code = response["code"] as? Int else { throw Failure.invalidData }
        guard code == 200 else { throw Failure.rejected(code) }
        let synced = (response["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        guard !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hasTimestamps = synced.range(of: #"\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
        return Record(source: "NetEase", synced: hasTimestamps ? synced : "", plain: hasTimestamps ? "" : synced,
                      synchronized: abs((match["duration"] as! Double) / 1000 - track.duration) <= 2)
    }

    private func lrcLib(_ track: Track, deadline: Date) async throws -> Record? {
        guard let response = try await request("https://lrclib.net/api/search", query: [
            URLQueryItem(name: "q", value: "\(track.title) \(track.artist)")
        ], source: "LRCLIB", deadline: deadline) else { return nil }
        guard let records = response as? [[String: Any]] else { throw Failure.invalidData }
        let matches = records.filter { record in
            guard normalize(record["trackName"] as? String) == normalize(track.title),
                  normalize(record["artistName"] as? String) == normalize(track.artist),
                  let duration = record["duration"] as? Double, duration.isFinite else { return false }
            return abs(duration - track.duration) <= 15 && record["instrumental"] as? Bool != true
        }.sorted { abs(($0["duration"] as! Double) - track.duration) < abs(($1["duration"] as! Double) - track.duration) }
        for match in matches {
            let synced = match["syncedLyrics"] as? String ?? ""
            let plain = match["plainLyrics"] as? String ?? ""
            if synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return Record(source: "LRCLIB", synced: synced, plain: plain,
                          synchronized: abs((match["duration"] as! Double) - track.duration) <= 2)
        }
        return nil
    }

    private func normalize(_ value: String?) -> String {
        (value ?? "").precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
