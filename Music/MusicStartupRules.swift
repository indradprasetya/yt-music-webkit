import Foundation

enum MusicStartupRules {
    static let manifestURL = URL(string: "https://indradprasetya.github.io/yt-music-webkit/messages/manifest.json")!
    static let versionKey = "StartupMessages.LastCheckedVersion"
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
        let launches: [Launch]?
        let versions: [String]?
        let page: String
    }

    static func check(version: String, manifestURL: URL = manifestURL,
                      defaults: UserDefaults = .standard, session: URLSession = session) async -> URL? {
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
            }) else { return nil }
            let rule = manifest.rules.first {
                $0.enabled && ($0.launches?.contains(launch) ?? true)
                    && ($0.versions?.contains(version) ?? true)
            }
            try Task.checkCancellation()
            defaults.set(version, forKey: versionKey)
            return rule.map { manifestURL.deletingLastPathComponent().appendingPathComponent($0.page) }
        } catch {
            return nil
        }
    }
}
