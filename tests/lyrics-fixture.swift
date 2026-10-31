import AppKit
import WebKit

final class LyricsTransport: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var titles: [Int: String] = [:]
    static var cancelled = 0
    static var recovered: Set<String> = []
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func parameter(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
        let title: String = Self.lock.withLock {
            Self.requests.append(request)
            if url.path.hasSuffix("/lyric") { return Self.titles[Int(parameter("id"))!]! }
            return String(parameter(url.host == "music.163.com" ? "s" : "q").dropLast(" Artist".count))
        }
        let recovered = Self.lock.withLock { Self.recovered.contains(title) }
        var status = 200
        var body: Any
        if !recovered && (title == "HTTP error" || title == "Cooldown") {
            status = title == "Cooldown" ? 429 : 502
            body = ["error": "unavailable"]
        } else if title == "Malformed" {
            body = ["unexpected": true]
        } else if title == "Timeout" && url.host == "music.163.com" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Trickle bytes so an idle timeout cannot enforce the total provider deadline.
            for chunk in 1...60 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(chunk) * 0.2) { [self] in
                    if Self.lock.withLock({ !stopped }) { client?.urlProtocol(self, didLoad: Data(" ".utf8)) }
                }
            }
            return
        } else if title == "Transient503" && url.host == "music.163.com" {
            body = ["code": -462]
        } else if title == "Transient503" && !recovered {
            status = 503
            body = ["error": "temporarily unavailable"]
            _ = Self.lock.withLock { Self.recovered.insert(title) }
        } else if url.host == "lrclib.net" {
            body = title == "No match" || title == "Plain" ? [] : [
                ["trackName": title, "artistName": "Wrong artist", "duration": 180, "syncedLyrics": "[00:01]Wrong artist"],
                ["trackName": title, "artistName": "Artist", "duration": 180,
                 "syncedLyrics": "[00:01.00]Fallback first\n[00:10.00]Fallback second", "plainLyrics": "", "instrumental": false]
            ]
        } else if title == "Fallback" || (title == "No match" && !recovered) {
            if title == "Fallback" { body = ["code": -462] }
            else { body = ["code": 200, "result": ["songs": [] as [Any]]] }
        } else if url.path.hasSuffix("/lyric") {
            let later = (2...11).map { index -> String in
                var line = String(format: "[%02d:%02d.00]Line %d", index * 10 / 60, index * 10 % 60, index)
                if index == 7 { line += " with a longer phrase that wraps inside a narrow panel" }
                return line
            }
            let credits = title == "Credits" ? ["[00:00.00]作词：Example Writer", "[00:00.00]Composer: Example Composer",
                "[00:00.00](Artist)", "[00:00.00](Justin Bieber)", "[00:02.00](La-la-la)",
                "[00:03.00](I love you)", "[00:04.00](Album)", "[00:05.00]Justin Bieber"] : []
            body = ["code": 200, "lrc": ["lyric": (credits + ["[00:01.00]First line", "[00:10.00]Second line"] + later).joined(separator: "\n")]]
        } else {
            let id = Self.lock.withLock { () -> Int in
                let next = Self.titles.count + 1
                Self.titles[next] = title
                return next
            }
            body = ["code": 200, "result": ["songs": [
                ["id": id, "name": title, "artists": [["name": "Wrong artist"]], "duration": 180000],
                ["id": id, "name": title + " (Live)", "artists": [["name": "Artist"]], "duration": 180000],
                ["id": id, "name": title, "artists": [["name": "Artist"]], "duration": title == "Plain" || title == "Better sync" ? 183000 : 180000]
            ]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Retry-After": "1"])!
        let send = { [self] in
            Self.lock.lock()
            let shouldSend = !stopped
            Self.lock.unlock()
            guard shouldSend else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if title == "Slow" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.6, execute: send) }
        else if title == "Pending" { DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: send) }
        else { send() }
    }
    override func stopLoading() {
        Self.lock.withLock { stopped = true; Self.cancelled += 1 }
    }
}

@MainActor final class FrameCapture: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
setbuf(stdout, nil)

@MainActor func check() async throws {
    let live = CommandLine.arguments.contains("--live")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpAdditionalHeaders = ["User-Agent": "Music/1.2.0 (https://github.com/indradprasetya/yt-music-webkit)"]
    if !live { configuration.protocolClasses = [LyricsTransport.self] }
    let provider = MusicLyricsProvider(session: URLSession(configuration: configuration))
    let suite = "MusicLyricsCheck.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let key = "MusicCustomLyricsEnabled"
    let offsetsKey = "MusicLyricsOffsetsByTrack"
    defer { defaults.removePersistentDomain(forName: suite) }
    let lyrics = MusicLyrics(provider: provider, defaults: defaults)
    guard lyrics.isEnabled else {
        throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synced lyrics must start enabled when no preference exists"])
    }
    assert(defaults.object(forKey: key) == nil, "Reading the default must not overwrite a saved preference")
    lyrics.isEnabled = false
    assert(!MusicLyrics(defaults: defaults).isEnabled, "A saved OFF choice must survive a new instance")
    lyrics.isEnabled = true
    assert(MusicLyrics(defaults: defaults).isEnabled, "A saved ON choice must survive a new instance")
    let webConfiguration = WKWebViewConfiguration()
    webConfiguration.websiteDataStore = .nonPersistent()
    let controller = webConfiguration.userContentController
    lyrics.connect(to: controller)
    let frameCapture = FrameCapture()
    controller.add(frameCapture, contentWorld: .defaultClient, name: "testFrame")
    controller.addUserScript(WKUserScript(source: "if (window !== window.top) webkit.messageHandlers.testFrame.postMessage(0);",
        injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
    let metadata = live ? [CommandLine.arguments[2], CommandLine.arguments[3]] : ["Fixture", "Artist"]
    let duration = live ? Double(CommandLine.arguments[4])! : 180
    let literal = String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!
    if CommandLine.arguments.contains("--media-session") || live {
        controller.addUserScript(WKUserScript(source: "const m = \(literal); navigator.mediaSession.metadata = new MediaMetadata({title:m[0],artist:m[1]});",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    controller.addUserScript(WKUserScript(source: """
        Object.defineProperty(document.querySelector('video'), 'duration', {get: () => \(duration)});
        window.fixtureTime = 12;
        Object.defineProperty(document.querySelector('video'), 'currentTime', {
            get: () => fixtureTime, set: value => { window.lastSeek = value; fixtureTime = value; }
        });
        window.fixtureReduceMotion = false;
        const platformMatchMedia = window.matchMedia.bind(window);
        window.matchMedia = query => query === '(prefers-reduced-motion: reduce)'
            ? {get matches() { return fixtureReduceMotion; }} : platformMatchMedia(query);
        window.lineIsCentered = () => {
            const row = document.querySelector('.lyrics-line.is-current');
            const scroll = document.querySelector('.lyrics-scroll');
            if (!row || !scroll) return false;
            const line = row.getBoundingClientRect();
            const viewport = scroll.getBoundingClientRect();
            return Math.abs(line.top + line.height / 2 - viewport.top - scroll.clientHeight / 2) < 2
                && document.querySelector('#tab-renderer').scrollTop === 0;
        };
        window.fetch = () => { throw new Error('Lyrics must use native networking'); };
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    lyrics.apply(to: controller)
    lyrics.apply(to: controller)
    let scriptCount = controller.userScripts.count
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: webConfiguration)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close(); lyrics.cancelLookup() }
    func js(_ value: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(value, in: nil, in: .defaultClient) { continuation.resume(with: $0) }
        }
    }
    func expect(_ value: String, _ reason: String, seconds: Double = 4) async throws {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            if (try? await js(value)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let notice = try? await js("document.querySelector('.lyrics-message')?.textContent || 'No notice'")
        throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(reason); notice: \(notice ?? "missing")"])
    }
    func changeTrack(_ title: String) async throws {
        let value = String(data: try JSONEncoder().encode(title), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("if (navigator.mediaSession.metadata) navigator.mediaSession.metadata.title = \(value); null")
        _ = try await web.callAsyncJavaScript("""
            document.querySelector('ytmusic-player-bar .title').textContent = title;
            await new Promise(requestAnimationFrame); return null;
            """, arguments: ["title": title], in: nil, contentWorld: .defaultClient)
    }
    func selectVersion(_ videoID: String) async throws {
        _ = try await web.callAsyncJavaScript("""
            history.replaceState({}, '', videoID ? '/watch?v=' + videoID : '/');
            document.querySelector('video').dispatchEvent(new Event('loadedmetadata'));
            await new Promise(requestAnimationFrame); return null;
            """, arguments: ["videoID": videoID], in: nil, contentWorld: .defaultClient)
    }
    func expectSavedOffset(_ value: Int?, for identity: String) async throws {
        for _ in 0..<100 {
            if lyrics.trackOffsets[identity] == value { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native per-song offset was not saved or removed"])
    }
    func update() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lyrics.update(in: web) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    let label = CommandLine.arguments.contains("--english") || live ? "Lyrics" : "Lirik"
    let pageHTML = """
        <!doctype html><html><body>
        <ytmusic-player-bar><span class="title">Fixture</span><span class="byline"><a href="/channel/fixture">Artist</a>, <a href="/channel/guest">Justin Bieber</a> • <a href="/browse/MPREfixture">Album</a></span></ytmusic-player-bar>
        <video></video><ytmusic-player-page><div role="tablist">
        <span role="tab" aria-selected="false">Up next</span><span role="tab" aria-selected="true" tabindex="0">\(label)</span>
        <span role="tab" aria-selected="false">Related</span></div>
        <div id="tab-renderer" style="height:400px"><div id="native-lyrics">Native lyrics</div></div>
        </ytmusic-player-page></body></html>
        """
    web.loadHTMLString(pageHTML, baseURL: URL(string: "https://music.youtube.com/"))
    try await expect("document.querySelectorAll('.lyrics-line').length >= 2 && !document.querySelector('.lyrics-scroll').hidden",
                     "Fetch real/native lyrics for \(metadata.joined(separator: " — "))", seconds: live ? 25 : 4)
    if live {
        let count = try await js("document.querySelectorAll('.lyrics-line').length")!
        let source = try await js("document.querySelector('.lyrics-source').textContent")!
        _ = try await js("window.initialIndex = document.querySelector('.lyrics-line.is-current')?.dataset.index; fixtureTime = 60; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("!!document.querySelector('.lyrics-line.is-current') && document.querySelector('.lyrics-line.is-current').dataset.index !== initialIndex", "Live lyrics must change highlight when seeking")
        print("PASS LIVE: \(metadata.joined(separator: " — ")); \(source); \(count) rendered lines; seek/highlight works")
        return
    }
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && document.querySelector('.lyrics-source').textContent.includes('NetEase')", "Native NetEase lookup and timing")
    _ = try await js("fixtureTime = 110; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-scroll').scrollTop > 100", "Start the previous song with lyrics scrolled down")
    _ = try await js("document.querySelector('.lyrics-scroll').dispatchEvent(new WheelEvent('wheel')); fixtureTime = 0; null")
    try await changeTrack("Intro")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && !document.querySelector('.lyrics-line.is-current') && document.querySelector('.lyrics-scroll').scrollTop === 0", "A new track before its first timestamp must start at the top, without inheriting the previous scroll")
    _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && document.querySelector('.lyrics-scroll').scrollTop > 0", "A new song must not inherit the previous manual-scroll pause")
    _ = try await js("fixtureTime = 110; null")
    try await changeTrack("Intro race")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Line 11' && document.querySelector('.lyrics-scroll').scrollTop > 100", "Model metadata arriving before the player resets its clock")
    _ = try await js("fixtureTime = 0; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("!document.querySelector('.lyrics-line.is-current') && document.querySelector('.lyrics-scroll').scrollTop === 0", "A late player clock reset must return the new lyrics to the top")
    _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    _ = try await js("document.querySelector('.lyrics-settings-button').click(); null")
    try await expect("!document.querySelector('.lyrics-settings-panel').hidden && document.querySelector('.lyrics-settings-button').getAttribute('aria-expanded') === 'true'", "The gear opens timing settings")
    _ = try await js("document.querySelector('[data-reset]').click(); null")
    try await expect("!document.querySelector('.lyrics-settings-panel').hidden", "Using a timing control must keep the popover open")
    try await expect("!!document.querySelector('button[aria-label=\"Close lyric timing\"]')", "Timing settings need an explicit close button")
    _ = try await js("document.querySelector('[data-offset=\"250\"]').click(); null")
    _ = try await js("document.querySelector('button[aria-label=\"Close lyric timing\"]').click(); null")
    try await expect("document.querySelector('.lyrics-settings-panel').hidden && document.querySelector('.lyrics-settings-button').getAttribute('aria-expanded') === 'false' && document.activeElement === document.querySelector('.lyrics-settings-button') && document.querySelector('.lyrics-settings-panel output').textContent === '+0.25 s'", "Closing timing settings must restore gear focus without changing the offset")
    _ = try await js("document.querySelector('.lyrics-settings-button').click(); document.querySelector('[data-reset]').click(); null")
    _ = try await js("document.body.click(); null")
    try await expect("document.querySelector('.lyrics-settings-panel').hidden && document.querySelector('.lyrics-settings-button').getAttribute('aria-expanded') === 'false'", "Clicking outside must dismiss timing settings")
    _ = try await js("""
        document.querySelector('.lyrics-settings-button').click();
        document.querySelector('[data-reset]').focus();
        window.escapeEvent = new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true});
        document.activeElement.dispatchEvent(escapeEvent); null
        """)
    try await expect("document.querySelector('.lyrics-settings-panel').hidden && document.activeElement === document.querySelector('.lyrics-settings-button') && escapeEvent.defaultPrevented", "Escape must dismiss timing settings, restore gear focus, and consume the key")
    try await expect("""
        (() => {
            const panel = document.querySelector('#tab-renderer');
            const scroll = document.querySelector('.lyrics-scroll');
            const bounds = scroll.getBoundingClientRect();
            const host = panel.getBoundingClientRect();
            return Math.abs(bounds.left - host.left) < 1 && Math.abs(bounds.right - host.right) < 1
                && getComputedStyle(panel).overflowY === 'hidden'
                && getComputedStyle(scroll).scrollbarWidth !== 'none'
                && getComputedStyle(scroll, '::-webkit-scrollbar-thumb').borderRadius === '10px';
        })()
        """, "Lyrics must fill the panel and have one rounded scrollbar")
    _ = try await js("fixtureTime = 2; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'First line'", "Seeking backward must update the highlighted line")
    try await expect("lineIsCentered()", "The first line needs empty space above it to remain centered")
    _ = try await js("fixtureTime = 110; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Line 11' && lineIsCentered()", "The last line needs empty space below it to remain centered")
    try await expect("""
        (() => {
            const rows = document.querySelectorAll('.lyrics-line');
            const active = getComputedStyle(rows[11]);
            const near = getComputedStyle(rows[9]);
            return new DOMMatrix(active.transform).a > new DOMMatrix(near.transform).a
                && [...rows].every(row => getComputedStyle(row).filter === 'none');
        })()
        """, "The active line grows and every lyric line stays sharp, regardless of distance")
    window.setContentSize(NSSize(width: 400, height: 500))
    try await expect("lineIsCentered() && document.querySelector('.lyrics-scroll').scrollWidth <= document.querySelector('.lyrics-scroll').clientWidth", "Resizing must preserve centering without horizontal scrolling")
    _ = try await js("""
        window.beforeWeightChange = [...document.querySelectorAll('.lyrics-line')].map(row => row.offsetHeight);
        fixtureTime = 70;
        document.querySelector('video').dispatchEvent(new Event('timeupdate')); null
        """)
    try await expect("""
        (() => {
            const rows = [...document.querySelectorAll('.lyrics-line')];
            const active = document.querySelector('.lyrics-line.is-current');
            return getComputedStyle(active).fontWeight === '700'
                && rows.filter(row => row !== active).every(row => getComputedStyle(row).fontWeight === '700'
                    && getComputedStyle(row).color !== getComputedStyle(active).color)
                && rows.every((row, index) => row.offsetHeight === beforeWeightChange[index])
                && lineIsCentered();
        })()
        """, "All lyric lines stay bold, inactive lines dim, and wrapped lines keep their height")
    window.setContentSize(NSSize(width: 900, height: 600))
    _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Seeking forward must update the highlighted line")
    try await changeTrack("Credits")
    try await expect("document.querySelectorAll('.lyrics-line.is-credit').length === 4 && document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Credits and parenthesized known performers must remain visible without becoming highlighted lyrics")
    try await expect("[...document.querySelectorAll('.lyrics-line.is-credit')].every(row => !row.querySelector('button') && getComputedStyle(row).fontSize === '14px' && getComputedStyle(row).fontWeight === '400')", "Credits use regular small text and do not offer lyric seeking")
    try await expect("['(La-la-la)', '(I love you)', '(Album)', 'Justin Bieber'].every(text => [...document.querySelectorAll('.lyrics-line')].some(row => row.textContent === text && !row.classList.contains('is-credit') && row.querySelector('button')))", "Vocals, album names, and sung artist names must not be mistaken for performer labels")
    _ = try await js("document.querySelector('a[href=\"/channel/guest\"]').href = '/browse/MPREother'; null")
    try await expect("document.querySelectorAll('.lyrics-line.is-credit').length === 3", "Performer styling must update when artist-link metadata changes")
    _ = try await js("document.querySelector('a[href=\"/browse/MPREother\"]').href = '/channel/guest'; null")
    try await expect("document.querySelectorAll('.lyrics-line.is-credit').length === 4", "Returning artist metadata must restore performer styling from cache")
    _ = try await js("fixtureTime = 0; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("!document.querySelector('.lyrics-line.is-current')", "Credits at time zero must not become the active lyric")
    _ = try await js("fixtureTime = 12; null")
    try await changeTrack("Intro race")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Return from credits to normal lyrics")
    _ = try await js("document.querySelector('.lyrics-settings-button').click(); document.querySelector('.lyrics-line button')?.click(); null")
    try await expect("lastSeek === 1 && document.querySelector('.lyrics-line.is-current')?.textContent === 'First line' && document.querySelector('.lyrics-settings-panel').hidden", "Clicking a timed lyric must dismiss settings and seek in the same click")
    try await selectVersion("fixtureAA01")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '0.00 s'", "An unconfigured version starts with zero offset")
    _ = try await js("document.querySelector('[data-offset=\"250\"]').click(); document.querySelectorAll('.lyrics-line button')[1].click(); null")
    try await expect("lastSeek === 10.25 && document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Click-to-seek must include the configured timing offset")
    try await expectSavedOffset(250, for: "video:fixtureAA01")
    assert(MusicLyrics(defaults: defaults).trackOffsets["video:fixtureAA01"] == 250, "A new native instance must read the saved offset")
    _ = try await js("document.documentElement.dataset.beforeOffsetReload = 'true'; null")
    web.loadHTMLString(pageHTML, baseURL: URL(string: "https://music.youtube.com/watch?v=fixtureAA01"))
    try await expect("!document.documentElement.dataset.beforeOffsetReload && !!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-settings-panel output').textContent === '+0.25 s'", "A full document load without apply must restore the latest saved offset")
    lyrics.isEnabled = false
    try await update()
    lyrics.isEnabled = true
    try await update()
    try await expect("!!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-settings-panel output').textContent === '+0.25 s'", "The song offset must survive a runtime restart through native preferences")
    try await selectVersion("fixtureBB02")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '0.00 s'", "A different video with identical metadata must not inherit the previous offset")
    _ = try await js("document.querySelector('[data-offset=\"-250\"]').click(); document.querySelector('[data-offset=\"-250\"]').click(); null")
    try await selectVersion("fixtureAA01")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '+0.25 s'", "Returning to a version must restore its own saved offset")
    _ = try await js("document.querySelector('[data-reset]').click(); null")
    try await expectSavedOffset(nil, for: "video:fixtureAA01")
    _ = try await js("document.documentElement.dataset.beforeOffsetReload = 'true'; null")
    web.loadHTMLString(pageHTML, baseURL: URL(string: "https://music.youtube.com/watch?v=fixtureAA01"))
    try await expect("!document.documentElement.dataset.beforeOffsetReload && !!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-settings-panel output').textContent === '0.00 s'", "A reset offset must not reappear after a full document load")
    try await selectVersion("fixtureBB02")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '-0.50 s'", "Reset must affect only the current version")
    _ = try await js("document.querySelector('[data-offset=\"250\"]').click(); document.querySelector('[data-offset=\"250\"]').click(); null")
    try await expectSavedOffset(nil, for: "video:fixtureBB02")
    try await selectVersion("")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '0.00 s'", "Missing video IDs fall back to track metadata")
    _ = try await js("document.querySelector('[data-offset=\"250\"]').click(); null")
    try await changeTrack("Cover version")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '0.00 s'", "The metadata fallback must separate different versions")
    try await changeTrack("Fixture")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-settings-panel output').textContent === '+0.25 s'", "Metadata fallback offsets must also be restored")
    _ = try await js("document.querySelector('[data-reset]').click(); null")
    try await expectSavedOffset(nil, for: #"track:["fixture","artist",180]"#)
    assert(defaults.object(forKey: offsetsKey) == nil, "Zero offsets must leave no stored entries or empty container")
    _ = try await js("""
        for (const payload of [
            {trackKey:'video:invalid', milliseconds:true},
            {trackKey:'video:invalid', milliseconds:1.5},
            {trackKey:'video:invalid', milliseconds:10001},
            {trackKey:'', milliseconds:250},
            {trackKey:'video:' + 'x'.repeat(2000), milliseconds:250}
        ]) webkit.messageHandlers.musicLyricsOffset.postMessage(payload);
        null
        """)
    try await Task.sleep(for: .milliseconds(100))
    assert(lyrics.trackOffsets.isEmpty && defaults.object(forKey: offsetsKey) == nil, "Malformed offset messages must not create preference entries")
    try await expect("lineIsCentered()", "Automatic scrolling must not pause itself")
    _ = try await js("""
        const scroll = document.querySelector('.lyrics-scroll');
        scroll.dispatchEvent(new WheelEvent('wheel', {deltaY: 100}));
        scroll.scrollTop = 40;
        fixtureTime = 60;
        document.querySelector('video').dispatchEvent(new Event('timeupdate')); null
        """)
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Line 6' && document.querySelector('.lyrics-scroll').scrollTop === 40", "Manual scrolling must pause auto-scroll while the highlight keeps following playback")
    _ = try await js("document.querySelectorAll('.lyrics-line button')[1].click(); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && lineIsCentered()", "Clicking a line must resume centered scrolling immediately")
    _ = try await js("""
        window.beforeAnimatedSeek = document.querySelector('.lyrics-scroll').scrollTop;
        document.querySelectorAll('.lyrics-line button')[11].click();
        window.seekStartsWithoutJump = document.querySelector('.lyrics-scroll').scrollTop === beforeAnimatedSeek; null
        """)
    try await expect("seekStartsWithoutJump", "Animated seeking must start from the visible position without an immediate jump")
    try await Task.sleep(for: .milliseconds(80))
    _ = try await js("""
        document.querySelector('.lyrics-scroll').dispatchEvent(new WheelEvent('wheel'));
        window.interruptedPosition = document.querySelector('.lyrics-scroll').scrollTop; null
        """)
    try await Task.sleep(for: .milliseconds(200))
    try await expect("Math.abs(document.querySelector('.lyrics-scroll').scrollTop - interruptedPosition) < 1", "Manual input must immediately stop an in-flight animation, not fight the user")
    _ = try await js("""
        document.querySelectorAll('.lyrics-line button')[2].click();
        document.querySelectorAll('.lyrics-line button')[5].click();
        document.querySelectorAll('.lyrics-line button')[1].click(); null
        """)
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && lineIsCentered()", "Rapid seek clicks must retarget from the current position and settle on the latest line")
    _ = try await js("""
        window.highlightsDuringScroll = [20, 30, 40].map((time, index) => {
            fixtureTime = time;
            document.querySelector('video').dispatchEvent(new Event(index === 1 ? 'seeking' : 'timeupdate'));
            const current = document.querySelector('.lyrics-line.is-current');
            return current?.textContent === `Line ${time / 10}` && getComputedStyle(current).color === 'rgb(255, 255, 255)';
        }); null
        """)
    try await expect("highlightsDuringScroll.every(Boolean)", "Highlight text and full brightness must follow the audio clock immediately, without waiting for scroll or color animation")
    _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('seeked')); null")
    try await expect("lineIsCentered()", "Following still settles after immediate highlight changes")
    _ = try await js("""
        fixtureReduceMotion = true;
        document.querySelectorAll('.lyrics-line button')[11].click();
        window.reducedMotionCenteredImmediately = lineIsCentered(); null
        """)
    try await expect("reducedMotionCenteredImmediately", "Reduced Motion must center immediately without a lingering scroll animation")
    _ = try await js("fixtureReduceMotion = false; document.querySelectorAll('.lyrics-line button')[1].click(); null")
    try await expect("lineIsCentered()", "Restore animated following after Reduce Motion")
    let requestCount = LyricsTransport.lock.withLock { LyricsTransport.requests.count }
    _ = try await js("document.querySelectorAll('.lyrics-line button')[11].click(); document.querySelectorAll('[role=tab]')[1].setAttribute('aria-selected','false'); null")
    try await expect("getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'", "Restore native lyrics on other tabs")
    _ = try await js("document.querySelectorAll('[role=tab]')[1].setAttribute('aria-selected','true'); null")
    try await expect("!!document.querySelector('.music-custom-lyrics-active') && document.querySelector('.lyrics-line.is-current')?.textContent === 'Line 11' && lineIsCentered()", "Returning to Lyrics must finish centering an animation interrupted by hiding the panel")
    assert(LyricsTransport.lock.withLock { LyricsTransport.requests.count } == requestCount, "Reuse cache on tab return")
    _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    _ = try await js("document.querySelector('#music-custom-lyrics').remove(); null")
    try await expect("!!document.querySelector('.lyrics-line.is-current')", "Restore a panel replaced by YouTube")
    try await changeTrack("Slow")
    try await expect("document.querySelector('.lyrics-message').textContent.includes('Looking') && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'", "Keep native lyrics while loading")
    try await expect("document.querySelector('#music-custom-lyrics').getBoundingClientRect().bottom <= document.querySelector('#native-lyrics').getBoundingClientRect().top", "Notice must occupy a row above native lyrics")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Finish a slow request")
    try await changeTrack("Plain")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('Unsynchronized') && !document.querySelector('.lyrics-scroll').hidden && !document.querySelector('.lyrics-line.is-current')", "Different durations must disable synchronization")
    try await expect("!document.querySelector('.lyrics-line button') && getComputedStyle(document.querySelector('.lyrics-line')).color === 'rgb(245, 245, 245)' && getComputedStyle(document.querySelector('.lyrics-line')).filter === 'none' && getComputedStyle(document.querySelector('.lyrics-line')).transform === 'none'", "Untimed text stays clear without blur or fabricated seek positions")
    try await changeTrack("Better sync")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('LRCLIB') && document.querySelector('.lyrics-line.is-current')?.textContent === 'Fallback second'", "Prefer a synchronized fallback over an unsynchronized primary result")
    try await changeTrack("Fallback")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('LRCLIB') && document.querySelector('.lyrics-line.is-current')?.textContent === 'Fallback second'", "API -462 must try LRCLIB rather than treating HTTP 200 as success")
    try await changeTrack("Transient503")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('LRCLIB') && document.querySelector('.lyrics-line.is-current')?.textContent === 'Fallback second'", "One transient 503 must recover automatically after Retry-After")
    if CommandLine.arguments.count == 1 {
        let started = Date()
        try await changeTrack("Timeout")
        try await expect("document.querySelector('.lyrics-message').textContent.includes('Looking') && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'", "Retain native lyrics during a stalled request")
        try await expect("document.querySelector('.lyrics-source').textContent.includes('LRCLIB') && !document.querySelector('.lyrics-scroll').hidden", "Actual native deadline must unblock the fallback provider", seconds: 13)
        assert(Date().timeIntervalSince(started) < 13, "Bound total provider time, not just idle time")
    }
    for title in ["No match", "HTTP error", "Malformed", "Cooldown"] {
        try await changeTrack(title)
        try await expect("!!document.querySelector('.lyrics-message button') && !document.querySelector('.lyrics-message').hidden && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'", "Keep native lyrics on \(title)")
        try await expect("document.querySelector('#music-custom-lyrics').getBoundingClientRect().bottom <= document.querySelector('#native-lyrics').getBoundingClientRect().top", "Errors must not cover lyrics")
        if title == "Cooldown" {
            try await expect("document.querySelector('.lyrics-message button').disabled", "Disable retry during server cooldown")
            try await expect("!document.querySelector('.lyrics-message button').disabled", "Allow retry after cooldown")
        } else if title == "No match" {
            _ = LyricsTransport.lock.withLock { LyricsTransport.recovered.insert(title) }
            _ = try await js("document.querySelector('.lyrics-message button').click(); null")
            try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Retry must invalidate a cached miss for the same track")
        }
    }
    try await changeTrack("Recovered")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && !document.querySelector('.lyrics-scroll').hidden", "Recover on next track")
    let cancelledBefore = LyricsTransport.lock.withLock { LyricsTransport.cancelled }
    try await changeTrack("Pending")
    try await expect("document.querySelector('.lyrics-message').textContent.includes('Looking')", "Start pending track B")
    try await Task.sleep(for: .milliseconds(400))
    try await changeTrack("Recovered")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Rapid A to B to A must restore cached A")
    try await Task.sleep(for: .milliseconds(100))
    assert(LyricsTransport.lock.withLock { LyricsTransport.cancelled > cancelledBefore }, "Returning to cached A must cancel B")
    _ = try await js("window.originalVideo = document.querySelector('video'); null")
    lyrics.isEnabled = false
    try await update()
    try await expect("!window.musicCustomLyrics && !document.querySelector('#music-custom-lyrics') && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'", "Disable restores native panel and cleans runtime")
    assert(controller.userScripts.count == scriptCount - 1)
    lyrics.isEnabled = true
    try await update()
    try await expect("!!document.querySelector('.lyrics-line.is-current') && originalVideo === document.querySelector('video')", "Enable immediately without replacing the media element")
    try await changeTrack("Pending")
    try await expect("document.querySelector('.lyrics-message').textContent.includes('Looking')", "Start pending lookup")
    try await Task.sleep(for: .milliseconds(400))
    lyrics.isEnabled = false
    try await update()
    try await expect("!window.musicCustomLyrics && !document.querySelector('#music-custom-lyrics')", "Disable must cancel without recreating the panel")
    assert(LyricsTransport.lock.withLock { LyricsTransport.cancelled > 0 }, "Cancel native transport")
    let exposed = try await web.evaluateJavaScript("!!window.musicCustomLyrics") as! Bool
    assert(!exposed)
    let calls = LyricsTransport.lock.withLock { LyricsTransport.requests.count }
    _ = try await js("window.webkit.messageHandlers.musicLyricsLookup.postMessage({title:'Fixture',artist:'Artist',duration:180}).catch(() => {}); null")
    try await Task.sleep(for: .milliseconds(100))
    assert(LyricsTransport.lock.withLock { LyricsTransport.requests.count } == calls, "Reject lookups when disabled")
    lyrics.isEnabled = true
    let payload = "{title:'Fixture',artist:'Artist',duration:180}"
    _ = try await js("const frame = document.createElement('iframe'); frame.srcdoc = '<body>Frame</body>'; document.body.append(frame); null")
    for _ in 0..<100 {
        if frameCapture.frame != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard let frame = frameCapture.frame else { fatalError("No subframe captured") }
    let probe = "webkit.messageHandlers.musicLyricsOffset.postMessage({trackKey:'video:blocked',milliseconds:500}); webkit.messageHandlers.musicLyricsLookup.postMessage(\(payload)).then(() => document.body.dataset.reply='allowed', error => document.body.dataset.reply=String(error)); null;"
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        web.evaluateJavaScript(probe, in: frame, in: .defaultClient) { result in
            continuation.resume(with: result.map { _ in () })
        }
    }
    try await expect("document.querySelector('iframe').contentDocument.body.dataset.reply?.includes('only on YouTube Music')", "Reject even same-origin subframes while enabled")
    web.loadHTMLString("<html><body><video></video></body></html>", baseURL: URL(string: "https://accounts.google.com/"))
    try await expect("location.hostname === 'accounts.google.com' && document.readyState === 'complete'", "Load foreign origin")
    _ = try await js(probe)
    try await expect("document.body.dataset.reply?.includes('only on YouTube Music')", "Reject foreign-origin main frame while enabled")
    assert(lyrics.trackOffsets.isEmpty, "Untrusted frames must not save timing offsets")
    assert(LyricsTransport.lock.withLock { LyricsTransport.requests.count } == calls, "Rejected frames must not contact providers")
    assert(MusicLyricsProvider.Track(["title": "", "artist": "Artist", "duration": 180.0]) == nil)
    assert(MusicLyricsProvider.Track(["title": "Fixture", "artist": "Artist", "duration": Double.infinity]) == nil)
    assert(MusicLyricsProvider.Track(["title": String(repeating: "a", count: 501), "artist": "Artist", "duration": 180.0]) == nil)
    print("PASS: \(label), native NetEase/LRCLIB fallback, provider errors, timeout, cooldown, cache, matching, sync, top notice, cleanup and cancellation")
}
Task { @MainActor in
    do { try await check(); exit(0) }
    catch {
        print("FAIL:", error.localizedDescription)
        if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String { print(message) }
        exit(1)
    }
}
app.run()
