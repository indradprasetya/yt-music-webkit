import Foundation

enum MusicStartupRules {
    static let manifestURL = URL(string: "https://indradprasetya.github.io/yt-music-webkit/messages/manifest.json")!
    static let versionKey = "StartupMessages.LastCheckedVersion"
    static let shownKeyPrefix = "StartupMessages.Shown."
    static let session = URLSession(configuration: .ephemeral)

    enum Launch: String, Decodable {
        case firstLaunch, versionChanged, regular
    }

    struct Manifest: Decodable {
        let schemaVersion: Int
        let rules: [Rule]
    }

    struct Rule: Decodable {
        let enabled: Bool
        let id: String?
        let launches: [Launch]?
        let versions: [String]?
        let page: String
    }

    struct Message {
        let url: URL
        let id: String?

        func markShown(defaults: UserDefaults) {
            guard let id else { return }
            defaults.set(true, forKey: shownKeyPrefix + id)
        }
    }

    static func check(version: String, manifestURL: URL = manifestURL,
                      defaults: UserDefaults = .standard, session: URLSession = session) async -> Message? {
        let previous = defaults.string(forKey: versionKey)
        let launch: Launch = previous == nil ? .firstLaunch : previous == version ? .regular : .versionChanged
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 3)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200, response.url == manifestURL,
                  data.count <= 65_536 else { return nil }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1 else { return nil }
            // Keep page navigation inside the trusted messages directory, including future rules.
            guard manifest.rules.allSatisfy({
                $0.page.range(of: #"^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.html$"#,
                              options: .regularExpression) != nil
                    && ($0.id.map { $0.range(of: #"^[A-Za-z0-9_-]{1,128}\z"#,
                                            options: .regularExpression) != nil } ?? true)
            }) else { return nil }
            let rule = manifest.rules.first {
                $0.enabled && ($0.launches?.contains(launch) ?? true)
                    && ($0.versions?.contains(version) ?? true)
                    && !($0.id.map { defaults.bool(forKey: shownKeyPrefix + $0) } ?? false)
            }
            try Task.checkCancellation()
            defaults.set(version, forKey: versionKey)
            return rule.map {
                Message(url: manifestURL.deletingLastPathComponent().appendingPathComponent($0.page), id: $0.id)
            }
        } catch {
            return nil
        }
    }
}
