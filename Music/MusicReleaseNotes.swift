import Foundation

enum MusicReleaseNotes {
    private struct Release: Decodable {
        let tag_name: String
        let body_html: String?
        let draft: Bool
    }

    static func load(version: String, session: URLSession = .shared,
                     defaults: UserDefaults = .standard) async -> (html: String, cached: Bool) {
        let tag = "v\(version)"
        let key = "GitHubReleaseNotes.HTML.\(tag)"
        let url = URL(string: "https://api.github.com/repos/indradprasetya/yt-music-webkit/releases/tags")!
            .appendingPathComponent(tag)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github.html+json", forHTTPHeaderField: "Accept")
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
            let body = (release.body_html ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let html = body.isEmpty ? "<p>No release notes have been added for this version yet.</p>" : body
            defaults.set(html, forKey: key)
            return (html, false)
        } catch {
            if let saved = defaults.string(forKey: key) { return (saved, true) }
            return ("<p>Release notes are not available right now. Please try again later.</p>", false)
        }
    }

    static func document(html: String, cached: Bool = false) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https: data:; base-uri https://github.com; form-action 'none'">
        <base href="https://github.com/indradprasetya/yt-music-webkit/">
        <style>
        :root { color-scheme: light dark; font: 13px/1.5 -apple-system, sans-serif; background: transparent; }
        body { margin: 8px 6px; color: CanvasText; background: transparent; overflow-wrap: anywhere; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.25em 0 .5em; }
        h1 { font-size: 18px; } h2 { font-size: 16px; } h3 { font-size: 14px; }
        main > :first-child { margin-top: 0; }
        p, ul, ol, pre, blockquote, table { margin: 0 0 1em; }
        ul, ol { padding-left: 1.5em; } li + li { margin-top: .3em; }
        a { color: LinkText; text-underline-offset: .15em; }
        a:focus-visible { outline: 2px solid Highlight; outline-offset: 2px; }
        ::selection { color: HighlightText; background: Highlight; }
        pre, code { font: .9em ui-monospace, monospace; } pre { overflow-x: auto; }
        img { max-width: 100%; height: auto; } table { border-collapse: collapse; }
        th, td { padding: .4em .6em; border: 1px solid GrayText; text-align: left; }
        </style></head><body>
        \(cached ? "<p role=\"status\">Couldn’t refresh — showing saved release notes.</p>" : "")
        <main aria-label="Release notes">\(html)</main>
        </body></html>
        """
    }
}
