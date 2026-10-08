import Foundation

enum MusicReleaseNotes {
    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let draft: Bool
    }

    static func load(version: String, session: URLSession = .shared,
                     defaults: UserDefaults = .standard) async -> (text: String, cached: Bool) {
        let tag = "v\(version)"
        let key = "GitHubReleaseNotes.\(tag)"
        let url = URL(string: "https://api.github.com/repos/indradprasetya/yt-music-webkit/releases/tags")!
            .appendingPathComponent(tag)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Music/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard release.tag_name == tag, !release.draft else {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()
            let body = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = body.isEmpty ? "No release notes have been added for this version yet." : body
            defaults.set(text, forKey: key)
            return (text, false)
        } catch {
            if let saved = defaults.string(forKey: key) { return (saved, true) }
            return ("Release notes are not available right now. Please try again later.", false)
        }
    }
}
