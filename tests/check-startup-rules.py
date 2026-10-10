#!/usr/bin/env python3
"""Exercise the native rules with an isolated defaults suite and mock HTTP; no Git."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = r'''
final class MessageProtocol: URLProtocol {
    static var body = ""
    static var status = 200
    static var offline = false
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let domain = "MusicStartupRulesCheck.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: domain)!
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [MessageProtocol.self]
let session = URLSession(configuration: configuration)
let endpoint = URL(string: "https://example.invalid/messages/manifest.json")!
func check(_ version: String) async -> MusicStartupRules.Message? {
    await MusicStartupRules.check(version: version, manifestURL: endpoint, defaults: defaults, session: session)
}
func rules(_ body: String) { MessageProtocol.body = "{\"schemaVersion\":1,\"rules\":[\(body)]}" }
func expect(_ version: String, _ filename: String?) async {
    let result = await check(version)
    assert(result?.url.lastPathComponent == filename, "Unexpected page: \(String(describing: result))")
}
Task {
    defer {
        defaults.removePersistentDomain(forName: domain)
        session.invalidateAndCancel()
    }
    rules(#"{"enabled":true,"launches":["firstLaunch"],"page":"first.html"},{"enabled":true,"launches":["versionChanged"],"page":"updated.html"},{"enabled":true,"launches":["regular"],"page":"regular.html"}"#)
    MessageProtocol.offline = true
    await expect("1.1.3", nil)
    assert(defaults.string(forKey: MusicStartupRules.versionKey) == nil)
    MessageProtocol.offline = false
    await expect("1.1.3", "first.html")
    await expect("1.1.3", "regular.html")
    MessageProtocol.offline = true
    await expect("1.1.4", nil)
    assert(defaults.string(forKey: MusicStartupRules.versionKey) == "1.1.3")
    MessageProtocol.offline = false
    await expect("1.1.4", "updated.html")
    await expect("1.1.4", "regular.html")
    rules(#"{"enabled":false,"page":"disabled.html"},{"enabled":true,"versions":["1.1.3"],"page":"targeted.html"},{"enabled":true,"page":"everyone.html"}"#)
    await expect("1.1.3", "targeted.html")
    await expect("1.1.4", "everyone.html")
    await expect("1.1.4", "everyone.html")
    await expect("9.0.0", "everyone.html")
    rules(#"{"enabled":true,"launches":[],"page":"empty.html"}"#)
    await expect("9.0.1", nil)
    assert(defaults.string(forKey: MusicStartupRules.versionKey) == "9.0.1")
    rules("")
    await expect("9.0.2", nil)
    assert(defaults.string(forKey: MusicStartupRules.versionKey) == "9.0.2")
    for page in ["../outside.html", "https://evil.invalid/page.html", "/absolute.html", "%2e%2e/out.html", "page.html?other=1", "//evil.invalid/page.html"] {
        rules("{\"enabled\":true,\"page\":\"\(page)\"}")
        await expect("9.0.3", nil)
        assert(defaults.string(forKey: MusicStartupRules.versionKey) == "9.0.2")
    }
    for body in ["invalid", #"{"schemaVersion":2,"rules":[]}"#, #"{"schemaVersion":1,"rules":[{"enabled":true,"launches":["unknown"],"page":"page.html"}]}"#] {
        MessageProtocol.body = body
        await expect("9.0.3", nil)
        assert(defaults.string(forKey: MusicStartupRules.versionKey) == "9.0.2")
    }
    rules(#"{"enabled":true,"page":"notices/support.html"}"#)
    for status in [301, 403, 404, 429, 500] {
        MessageProtocol.status = status
        await expect("9.0.3", nil)
        assert(defaults.string(forKey: MusicStartupRules.versionKey) == "9.0.2")
    }
    MessageProtocol.status = 200
    await expect("9.0.3", "support.html")
    rules(#"{"enabled":true,"id":"google-layout-120","versions":["1.1.3"],"page":"warning.html"}"#)
    await expect("1.2.0", nil)
    let warning = await check("1.1.3")
    assert(warning?.id == "google-layout-120")
    assert(warning?.url.lastPathComponent == "warning.html")
    await expect("1.1.3", "warning.html") // A check alone must not consume the message.
    warning!.markShown(defaults: defaults)
    await expect("1.1.3", nil)
    let reopenedDefaults = UserDefaults(suiteName: domain)!
    let repeated = await MusicStartupRules.check(version: "1.1.3", manifestURL: endpoint,
                                                defaults: reopenedDefaults, session: session)
    assert(repeated == nil, "Shown IDs must persist beyond the defaults instance")
    rules(#"{"enabled":true,"id":"google-layout-120","page":"renamed.html"},{"enabled":true,"id":"next-warning","page":"warning.html"},{"enabled":true,"page":"regular.html"}"#)
    let next = await check("1.1.3")
    assert(next?.id == "next-warning", "Skip a shown ID, even if its page changed")
    next!.markShown(defaults: defaults)
    await expect("1.1.3", "regular.html")
    await expect("1.2.0", "regular.html")
    for id in ["", " ", "bad/id", #"bad\n"#, "café", String(repeating: "x", count: 129)] {
        rules("{\"enabled\":true,\"id\":\"\(id)\",\"page\":\"warning.html\"}")
        await expect("9.0.4", nil)
        assert(defaults.string(forKey: MusicStartupRules.versionKey) == "1.2.0")
    }
    for request in MessageProtocol.requests {
        assert(request.url == endpoint, "No version or user identifier is sent")
        assert(request.timeoutInterval == 3)
        assert(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
    print("PASS: launch state, targeting, order, once-per-ID persistence, repeatable rules, failures, and validation")
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopRun()
'''
with tempfile.TemporaryDirectory(prefix="music-startup-rules-") as directory:
    script = Path(directory) / "main.swift"
    script.write_text((root / "Music/MusicStartupRules.swift").read_text() + "\n" + checks)
    subprocess.run(["xcrun", "swift", str(script)], check=True, timeout=90)
