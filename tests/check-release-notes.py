#!/usr/bin/env python3
"""Run python3 tests/check-release-notes.py; no app build, Git, or network needed."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = r'''
final class ReleaseProtocol: URLProtocol {
    static var body = "<h2>What’s New</h2><ul><li>First description</li></ul>"
    static var tag = "v1.1.0"
    static var status = 200
    static var offline = false
    static var invalidJSON = false
    static var draft = false
    static var requests = [URLRequest]()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        let data = Self.invalidJSON ? Data("invalid".utf8) : try! JSONSerialization.data(withJSONObject: [
            "tag_name": Self.tag, "body_html": Self.body, "draft": Self.draft
        ])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let domain = "MusicReleaseNotesCheck.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: domain)!
defaults.set("## Old raw Markdown", forKey: "GitHubReleaseNotes.v1.1.1")
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [ReleaseProtocol.self]
let session = URLSession(configuration: configuration)
Task {
    defer {
        defaults.removePersistentDomain(forName: domain)
        session.invalidateAndCancel()
    }
    let first = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(first.html == ReleaseProtocol.body && !first.cached)
    ReleaseProtocol.body = "<h2>Fixed</h2><ul><li><strong>Edited</strong> on GitHub</li></ul>"
    let edited = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(edited.html == ReleaseProtocol.body && !edited.cached, "Reopening must fetch edits")
    assert(ReleaseProtocol.requests.count == 2)
    for request in ReleaseProtocol.requests {
        assert(request.url!.path.hasSuffix("/releases/tags/v1.1.0"))
        assert(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.html+json")
        assert(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        assert(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }
    ReleaseProtocol.offline = true
    let saved = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(saved.html == edited.html && saved.cached)
    let missing = await MusicReleaseNotes.load(version: "1.1.1", session: session, defaults: defaults)
    assert(missing.html.contains("not available") && !missing.cached, "Cache must be isolated by version")
    ReleaseProtocol.offline = false
    for status in [404, 403, 429, 500] {
        ReleaseProtocol.status = status
        let failed = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
        assert(failed.html == edited.html && failed.cached)
    }
    ReleaseProtocol.status = 200
    ReleaseProtocol.tag = "v1.1.1"
    let wrong = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(wrong.html == edited.html && wrong.cached, "Never show another version's notes")
    ReleaseProtocol.tag = "v1.1.0"
    ReleaseProtocol.invalidJSON = true
    let invalid = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(invalid.html == edited.html && invalid.cached)
    ReleaseProtocol.invalidJSON = false
    ReleaseProtocol.draft = true
    let draft = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(draft.html == edited.html && draft.cached)
    ReleaseProtocol.draft = false
    ReleaseProtocol.body = " \r\n "
    let empty = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(empty.html.contains("No release notes") && !empty.cached)
    ReleaseProtocol.offline = true
    let savedEmpty = await MusicReleaseNotes.load(version: "1.1.0", session: session, defaults: defaults)
    assert(savedEmpty.html == empty.html && savedEmpty.cached, "Empty notes must replace stale notes")
    let page = MusicReleaseNotes.document(html: edited.html)
    assert(page.contains("<h2>Fixed</h2><ul><li><strong>Edited</strong> on GitHub</li></ul>"))
    assert(!page.contains("What’s New in This Version"), "The app must not duplicate the release heading")
    assert(page.contains("default-src 'none'") && page.contains("color-scheme: light dark"))
    assert(!page.contains("showing saved release notes"))
    assert(MusicReleaseNotes.document(html: edited.html, cached: true).contains("showing saved release notes"))
    print("PASS: rendered release HTML, live edits, cache isolation, empty/error states, and document styling")
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopRun()
'''
with tempfile.TemporaryDirectory(prefix="music-notes-check-") as directory:
    script = Path(directory) / "main.swift"
    script.write_text((root / "Music/MusicReleaseNotes.swift").read_text() + "\n" + checks)
    subprocess.run(["xcrun", "swift", str(script)], check=True, timeout=90)
