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
            if url.host == "api.betterlyrics.org" { return parameter("s") }
            if url.host == "api.lrcmux.dev" { return parameter("title") }
            if url.host == "api.amll.dev" {
                if url.path.hasSuffix("/get") { return Self.titles[Int(parameter("id")) ?? 0] ?? "" }
                return parameter("musicName")
            }
            if url.path.contains("/song/lyric") { return Self.titles[Int(parameter("id"))!]! }
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
        } else if url.host == "api.betterlyrics.org" {
            if title == "Better miss" || (title == "Better words" && parameter("al") != "Album") {
                status = 401
                body = ["error": "API key required", "message": "Uncached queries require a valid API key"]
            } else if title == "Pause demo" {
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='10' end='12'>First vocal with a long line that wraps over several lines in a narrow lyrics panel</p><p begin='25' end='28'>Next vocal</p><p begin='30' end='32'>Short gap</p></body></tt>"]
            } else if title == "Pronunciation generated" {
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='5'><span begin='1' end='3'>夜</span><span begin='3' end='5'>だ</span></p></body></tt>"]
            } else if title == "Pronunciation layout" {
                var lines = ""
                for index in 0..<12 {
                    let start = index * 10 + 1
                    let end = start + 8
                    lines += "<p begin='\(start)' end='\(end)'>夜の街を一緒に歩こう</p>"
                }
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body>\(lines)</body></tt>"]
            } else if title == "Latin demo" {
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='5'><span begin='1' end='5'>Café déjà vu 👩‍🎤 123</span></p></body></tt>"]
            } else if title == "Language demo" {
                body = ["ttml": """
                <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body>
                <p begin="1" end="8"><span begin="1" end="8">明日は晴れる</span><span ttm:role="x-roman" xml:lang="ja-Latn">ashita wa hareru</span><span ttm:role="x-translation" xml:lang="id">Besok langit akan cerah</span><span ttm:role="x-translation" xml:lang="en">Tomorrow will be sunny</span></p>
                <p begin="10" end="18"><span begin="10" end="18">함께 걸어요</span><span ttm:role="x-roman" xml:lang="ko-Latn"><span begin="10" end="14">hamkke </span><span begin="14" end="18">georeoyo</span></span><span ttm:role="x-translation" xml:lang="id">Mari berjalan bersama</span><span ttm:role="x-translation" xml:lang="en">Let us walk together</span></p>
                <p begin="20" end="28"><span begin="20" end="28">一起看星星</span><span ttm:role="x-roman" xml:lang="zh-Latn">yì qǐ kàn xīng xing</span><span ttm:role="x-translation" xml:lang="id">Bersama melihat bintang</span><span ttm:role="x-translation" xml:lang="en">Watch the stars together</span></p>
                </body></tt>
                """]
            } else if title == "Syllable wrap" {
                let parts = ["Sedang ", "tak ", "mudah ", "bertemu ", "ra", "sa ", "se", "nang"]
                let spans = parts.enumerated().map { "<span begin='\($0.offset + 1)' end='\($0.offset + 2)'>\($0.element)</span>" }.joined()
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='10'>\(spans)</p></body></tt>"]
            } else if title == "Better words" || title == "Better out of range" || title == "Priority words" {
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body dur='3:00'><div><p begin='1' end='4'><span begin='1' end='2'>Hello </span><span begin='2' end='3'>world</span></p><p begin='10' end='12'>Second line</p></div></body></tt>"]
            } else if ["Priority lines", "Priority NetEase words", "Priority LRCLIB words", "Priority lrcmux words"].contains(title) {
                body = ["ttml": "<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='4'>Hello world</p><p begin='10' end='12'>Second line</p></body></tt>"]
            } else {
                status = 404
                body = ["error": "Not found"]
            }
        } else if url.host == "api.lrcmux.dev" {
            if title.hasPrefix("Mux ") || title == "Better miss" || title.hasPrefix("Priority ") {
                let duration = title == "Mux wrong version" ? 190 : 180
                let artist = title == "Mux wrong artist" ? "Someone else" : "Artist"
                let wordEnd = title == "Mux invalid words" ? 190000 : 2000
                let origin = parameter("album") == "Deezer version" ? "deezer" : "kugou"
                body = ["track": ["title": title, "artist": artist, "album": "Album", "duration": duration, "isrc": "", "cover": [:]],
                        "meta": ["level": title.hasPrefix("Priority ") && !title.hasSuffix("words") ? "line" : "word", "source": ["id": origin]],
                        "lines": [
                            ["text": "Hello world", "start": 1000, "end": 4000,
                             "words": [["text": "Hello ", "start": 1000, "end": wordEnd], ["text": "world", "start": 2000, "end": 3000]]],
                            ["text": "Second line", "start": 10000, "end": 12000, "words": []]
                        ]]
            } else {
                status = 404
                body = ["title": "Not Found", "detail": "no lyrics found"]
            }
        } else if url.host == "api.amll.dev" {
            if title == "AMLL partial error" {
                status = 502
                body = ["error": "unavailable"]
            } else if title == "AMLL busy" {
                status = 429
                body = ["error": "busy"]
            } else if !title.hasPrefix("AMLL ") {
                body = ["status": 200, "data": ["items": [], "pagination": ["page": 1, "pageSize": 10, "total": 0, "totalPages": 0, "hasMore": false]]]
            } else {
                let id = Self.lock.withLock { Self.titles.first { $0.value == title }?.key ?? 9000 }
                if id == 9000 { Self.lock.withLock { Self.titles[id] = title } }
                var song: [String: Any] = ["id": id, "filename": "fixture-\(id).ttml", "musicNames": [title],
                    "artistNames": ["Artist"], "albumNames": [], "ncmMusicIds": [String(id)],
                    "qqMusicIds": [], "appleMusicIds": [], "spotifyIds": [], "isrcs": [],
                    "authorIds": [], "authorUsernames": [], "format": "ttml"]
                if title == "AMLL wrong version" { song["ncmMusicIds"] = ["999999"] }
                if title == "AMLL wrong artist" { song["artistNames"] = ["Someone else"] }
                if url.path.hasSuffix("/search") {
                    var items = [song]
                    if title == "AMLL partial" {
                        var second = song
                        second["id"] = id + 10000
                        Self.lock.withLock { Self.titles[id + 10000] = "AMLL partial error" }
                        items.append(second)
                    }
                    body = ["status": 200, "data": ["items": items, "pagination": ["page": 1, "pageSize": 10, "total": items.count, "totalPages": 1, "hasMore": false]]]
                } else {
                    let text = title == "AMLL partial" ? "<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='4'>First line</p><p begin='10' end='12'>Second line</p></body></tt>" : title == "AMLL malformed" ? "<tt><broken>" : title == "AMLL entity" ? "<!DOCTYPE tt [<!ENTITY external SYSTEM 'file:///etc/hosts'>]><tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='4'>&external;</p></body></tt>" : """
                        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
                        <body dur="00:03:00.000"><div begin="0.115" end="00:03:00.000">
                        <p begin="00:01.000" end="00:04.000"><span begin="1" end="2">Hello</span> <span begin="00:00:02.000" end="3">world</span><span ttm:role="x-translation">Translation</span><span ttm:role="x-roman">Romanization</span><span ttm:role="x-bg"><span begin="2" end="3">Backing</span></span></p>
                        <p begin="10" end="12">Second line</p>
                        </div></body></tt>
                        """
                    song["lyrics"] = text
                    body = ["status": 200, "data": song]
                }
            }
        } else if url.host == "lrclib.net" {
            if title == "Blank lyric lines" || title == "Only blank lyrics" {
                let vocals = title == "Blank lyric lines" ? """
                      - text: First visible line
                        start_ms: 1000
                      - text: 'Second 👩‍🎤 line'
                        start_ms: 10000
                    """ : ""
                body = [["trackName": title, "artistName": "Artist", "duration": 180,
                         "syncedLyrics": "", "plainLyrics": "", "lyricsfile": """
                    version: '1.0'
                    metadata:
                      title: \(title)
                      artist: Artist
                      duration_ms: 180000
                    lines:
                      - text: ''
                        start_ms: 0
                      - text: '   '
                        start_ms: 5000
                      - text: '\u{00A0}\u{200B}\u{200D}'
                        start_ms: 6000
                    \(vocals)
                    """, "instrumental": false]]
            } else if ["AMLL standalone", "AMLL partial", "Priority lrcmux"].contains(title) { body = [] }
            else if ["Cross source", "Priority words", "Priority LRCLIB words"].contains(title) {
                body = [["trackName": title, "artistName": "Artist", "duration": 180,
                         "syncedLyrics": "[00:01.00]First line\n[00:10.00]Second line",
                         "lyricsfile": """
                         version: '1.0'
                         metadata:
                           title: \(title)
                           artist: Artist
                           duration_ms: 180000
                         lines:
                           - text: 'First line'
                             start_ms: 1000
                             end_ms: 4000
                             words:
                               - text: 'First '
                                 start_ms: 1000
                                 end_ms: 2000
                               - text: line
                                 start_ms: 2000
                                 end_ms: 3000
                         plain: 'First line'
                         """, "plainLyrics": "", "instrumental": false]]
            } else {
                body = ["No match", "Plain", "Metadata only", "Metadata with plain", "Metadata with timing"].contains(title) ? [] : [
                ["trackName": title, "artistName": "Wrong artist", "duration": 180, "syncedLyrics": "[00:01]Wrong artist"],
                ["trackName": title, "artistName": "Artist", "duration": 180,
                 "syncedLyrics": "[00:01.00]Fallback first\n[00:10.00]Fallback second", "plainLyrics": "", "instrumental": false]
                ]
            }
        } else if title == "AMLL standalone" {
            body = ["code": -462]
        } else if ["Fallback", "Blank lyric lines", "Only blank lyrics", "Priority LRCLIB", "Priority lrcmux"].contains(title) || (title == "No match" && !recovered) {
            if title != "No match" { body = ["code": -462] }
            else { body = ["code": 200, "result": ["songs": [] as [Any]]] }
        } else if title == "Word timing" && url.path == "/api/search/pc" {
            body = ["code": -462]
        } else if url.path.contains("/song/lyric") {
            if title == "Credit fallback" {
                body = ["code": 200, "lrc": ["lyric": "[00:00.00]Composer: Example Writer"]]
            } else if title == "Better words" || title == "Better out of range" {
                let invalid = title == "Better words" ? "[1000,1000](1000,0,0)Hello" : "[200000,1000](200000,1000,0)Hello"
                body = ["code": 200, "yrc": ["lyric": invalid],
                        "lrc": ["lyric": "[00:01.00]First line\n[00:10.00]Second line"]]
            } else if title.hasPrefix("Metadata ") {
                let credits = #"{"t":-1,"c":[{"tx":"作词: "},{"tx":"Example Writer"}]}"#
                let plain = title == "Metadata with timing" ? "\n[00:01.00]First real line\n[00:10.00]Second real line"
                    : title == "Metadata with plain" ? "\nFirst real line\nSecond real line" : ""
                body = ["code": 200, "lrc": ["lyric": credits + plain], "yrc": ["lyric": credits]]
            } else if title == "AMLL lyric failure" || title == "AMLL partial" {
                body = ["code": -462]
            } else if ["Priority words", "Priority NetEase words"].contains(title) {
                body = ["code": 200, "yrc": ["lyric": "[1000,4000](1000,1000,0)Hello (2000,1000,0)world"]]
            } else if title == "Word timing", url.path.hasSuffix("/v1"), parameter("yv") == "0",
               (Int(parameter("id")) ?? 0) >= 10000 {
                body = ["code": 200, "yrc": ["lyric": "[1000,4000](1000,1000,0)Hello (2000,1000,0)world"]]
            } else {
                let later = (2...11).map { index -> String in
                    var line = String(format: "[%02d:%02d.00]Line %d", index * 10 / 60, index * 10 % 60, index)
                    if index == 7 { line += " with a longer phrase that wraps inside a narrow panel" }
                    return line
                }
                let credits = title == "Credits" ? ["[00:00.00]作词：Example Writer", "[00:00.00]Composer: Example Composer",
                    "[00:00.00](Artist)", "[00:00.00](Justin Bieber)", "[00:02.00](La-la-la)",
                    "[00:03.00](I love you)", "[00:04.00](Album)", "[00:05.00]Justin Bieber"] : []
                body = ["code": 200, "lrc": ["lyric": (credits + ["[00:01.00]First line", "[00:10.00]Second line"] + later).joined(separator: "\n")]]
            }
        } else {
            let id = Self.lock.withLock { () -> Int in
                let next = Self.titles.count + 1
                Self.titles[next] = title
                if title == "Word timing" { Self.titles[next + 10000] = title }
                return next
            }
            if title == "Word timing" {
                body = ["code": 200, "result": ["songs": [
                    ["id": id, "name": title, "ar": [["name": "Artist"]], "dt": 180000],
                    ["id": id + 10000, "name": title, "ar": [["name": "Artist"]], "dt": 180500]
                ]]]
            } else {
                body = ["code": 200, "result": ["songs": [
                ["id": id, "name": title, "artists": [["name": "Wrong artist"]], "duration": 180000],
                ["id": id, "name": title + " (Live)", "artists": [["name": "Artist"]], "duration": 180000],
                ["id": id, "name": title, "artists": [["name": "Artist"]], "duration": title == "Plain" || title == "Better sync" ? 183000 : 180000]
                ]]]
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let retryAfter = title == "AMLL busy" ? "30" : title == "Cooldown" ? "3" : "1"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Retry-After": retryAfter])!
        let send = { [self] in
            Self.lock.lock()
            let shouldSend = !stopped
            Self.lock.unlock()
            guard shouldSend else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if title == "Slow" || title == "Background slow" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.6, execute: send) }
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

@MainActor func checkPronunciationScrolling(
    js: (String) async throws -> Any?,
    expect: (String, String) async throws -> Void,
    changeTrack: (String) async throws -> Void,
    snapshot: (String) async throws -> Void
) async throws {
    try await expect("!!document.querySelector('.lyrics-pronunciation-button')", "Load pronunciation controls before testing layout")
    try await changeTrack("Pronunciation layout")
    try await expect("document.querySelectorAll('.lyrics-line').length === 12 && !document.querySelector('.lyrics-pronunciation-button').hidden", "Load a scrollable non-Latin song")
    _ = try await js("""
            document.body.style.cssText = 'margin:0;background:#1d2228;color:white;font-family:-apple-system,BlinkMacSystemFont,sans-serif';
            document.querySelector('ytmusic-player-bar').style.cssText = 'display:block;padding:24px;font-size:18px;font-weight:600';
            document.querySelector('.byline').style.cssText = 'display:block;font-size:13px;font-weight:400;margin-top:6px';
            document.querySelector('video').style.display = 'none';
            document.querySelector('ytmusic-player-page').style.display = 'block';
            document.querySelector('#tab-renderer').style.cssText = 'height:400px;width:280px;margin:0 auto';
            document.querySelector('[role=tablist]').style.cssText = 'display:flex;justify-content:center;gap:24px;padding:12px';
        fixtureTime = 52;
        document.querySelector('video').dispatchEvent(new Event('timeupdate'));
        window.languageHandler = webkit.messageHandlers.musicLyricsLanguage;
        window.originalLanguagePost = languageHandler.postMessage.bind(languageHandler);
        languageHandler.postMessage = message => message.action === 'pronunciation'
            ? new Promise(resolve => { window.pendingPronunciation = resolve; }) : originalLanguagePost(message);
        window.pronunciationEntries = Array.from({length:12}, () => ({text:'yoru no machi o issho ni arukou '.repeat(3), words:[]}));
        window.observeLyricPosition = node => {
                cancelAnimationFrame(window.positionFrame || 0);
            window.readingAnchor = node;
            const top = node.getBoundingClientRect().top;
            window.lyricDrift = 0;
            window.observeUntil = performance.now() + 700;
            const sample = () => {
                lyricDrift = Math.max(lyricDrift, Math.abs(node.getBoundingClientRect().top - top));
                    if (performance.now() < observeUntil) window.positionFrame = requestAnimationFrame(sample);
            };
                window.positionFrame = requestAnimationFrame(sample);
        };
        null;
        """)
    try await expect("lineIsCentered()", "Center the original lyric before toggling")
    _ = try await js("observeLyricPosition(document.querySelector('.lyrics-line.is-current .lyrics-seek')); document.querySelector('.lyrics-pronunciation-button').click(); null")
    try await expect("!!window.pendingPronunciation", "Hold the generated pronunciation to exercise delayed layout")
    _ = try await js("observeLyricPosition(readingAnchor); pendingPronunciation({lines:pronunciationEntries}); queueMicrotask(() => window.pronunciationFadesIn = document.querySelector('.lyrics-pronunciation').getAnimations().some(animation => animation.effect.getTiming().duration === 180)); null")
    try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => !node.hidden && node.textContent)", "Show delayed pronunciation")
    try await Task.sleep(for: .milliseconds(720))
    try await expect("lyricDrift < 2", "Delayed pronunciation must keep the original lyric still on every frame")
    try await expect("pronunciationFadesIn", "New pronunciation must fade in over 180 ms")
    try await snapshot("lyrics-pronunciation-anchored")
    _ = try await js("observeLyricPosition(readingAnchor); document.querySelector('.lyrics-pronunciation-button').click(); window.pronunciationFadesOut = !document.querySelector('.lyrics-pronunciation').hidden && document.querySelector('.lyrics-pronunciation').getAnimations().some(animation => animation.effect.getTiming().duration === 180); null")
    try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => node.hidden)", "Finish hiding pronunciation")
    try await Task.sleep(for: .milliseconds(720))
    try await expect("lyricDrift < 2", "Hiding pronunciation must keep the original lyric still")
    try await expect("pronunciationFadesOut", "Pronunciation must fade out before collapsing its space")

    for time in [2, 112] {
        _ = try await js("fixtureTime = \(time); document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("lineIsCentered()", "Center boundary lyric before changing its height")
        _ = try await js("observeLyricPosition(document.querySelector('.lyrics-line.is-current .lyrics-seek')); document.querySelector('.lyrics-pronunciation-button').click(); null")
        try await Task.sleep(for: .milliseconds(720))
        try await expect("lyricDrift < 2 && !document.querySelector('.lyrics-pronunciation').hidden", "Cached pronunciation must preserve first and last lyric positions")
        _ = try await js("document.querySelector('.lyrics-pronunciation-button').click(); null")
        try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => node.hidden)", "Collapse pronunciation before the next boundary")
    }

    _ = try await js("""
        const scroll = document.querySelector('.lyrics-scroll');
        scroll.dispatchEvent(new WheelEvent('wheel'));
        scroll.scrollTop = 150;
        const middle = scroll.getBoundingClientRect().top + scroll.clientHeight / 2;
        const anchor = [...document.querySelectorAll('.lyrics-seek')].find(node => node.getBoundingClientRect().bottom >= middle);
        observeLyricPosition(anchor);
        document.querySelector('.lyrics-pronunciation-button').click();
        fixtureTime = 102;
        document.querySelector('video').dispatchEvent(new Event('timeupdate'));
        null;
        """)
    try await Task.sleep(for: .milliseconds(720))
    try await expect("lyricDrift < 2", "Toggling pronunciation must preserve manual reading and its auto-scroll pause")
    _ = try await js("document.querySelector('.lyrics-pronunciation-button').click(); document.querySelector('.lyrics-pronunciation-button').click(); null")
    try await Task.sleep(for: .milliseconds(240))
    try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => !node.hidden)", "Rapid OFF/ON must ignore the obsolete fade-out")
    _ = try await js("fixtureReduceMotion = true; document.querySelector('.lyrics-pronunciation-button').click(); window.hiddenImmediately = [...document.querySelectorAll('.lyrics-pronunciation')].every(node => node.hidden && node.getAnimations().length === 0); null")
    try await expect("hiddenImmediately", "Reduced Motion must hide pronunciation immediately without animations")
    _ = try await js("document.querySelector('.lyrics-pronunciation-button').click(); window.shownImmediately = [...document.querySelectorAll('.lyrics-pronunciation')].every(node => !node.hidden && node.getAnimations().length === 0); null")
    try await expect("shownImmediately", "Reduced Motion must show pronunciation immediately without animations")
    _ = try await js("fixtureReduceMotion = false; document.querySelectorAll('.lyrics-seek')[8].click(); null")
    try await expect("Math.abs(document.querySelector('.lyrics-line.is-current .lyrics-seek').getBoundingClientRect().top + document.querySelector('.lyrics-line.is-current .lyrics-seek').getBoundingClientRect().height / 2 - document.querySelector('.lyrics-scroll').getBoundingClientRect().top - document.querySelector('.lyrics-scroll').clientHeight / 2) < 4", "Seeking must center the original lyric when pronunciation is visible")
    try await snapshot("lyrics-pronunciation-seek")
    _ = try await js("""
        const bottomScroll = document.querySelector('.lyrics-scroll');
        bottomScroll.dispatchEvent(new WheelEvent('wheel'));
        bottomScroll.scrollTop = bottomScroll.scrollHeight;
        observeLyricPosition([...document.querySelectorAll('.lyrics-seek')].at(-1));
        document.querySelector('.lyrics-pronunciation-button').click();
        null;
        """)
    try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => node.hidden)", "Collapse pronunciation at the manual scroll boundary")
    _ = try await js("fixtureTime = 102; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await Task.sleep(for: .milliseconds(720))
    try await expect("lyricDrift < 2", "Manual reading at the bottom must remain still after collapse and a playback update")
    _ = try await js("languageHandler.postMessage = originalLanguagePost; null")
    print("PASS: pronunciation anchoring, delayed content, cached toggles, wrapped first/last lyrics, manual reading, rapid reversal, Reduced Motion and seeking")
}

@MainActor func check() async throws {
    let live = CommandLine.arguments.contains("--live")
    let plainUI = CommandLine.arguments.contains("--plain-ui-only")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpAdditionalHeaders = ["User-Agent": "Music/1.2.0 (https://github.com/indradprasetya/yt-music-webkit)"]
    if !live { configuration.protocolClasses = [LyricsTransport.self] }
    let provider = MusicLyricsProvider(session: URLSession(configuration: configuration))
    if CommandLine.arguments.contains("--translation-data-only") {
        let xml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
        <head><metadata><iTunesMetadata><translations><translation xml:lang="id"><text for="L2">Halo dunia</text></translation></translations>
        <transliterations><transliteration xml:lang="ko-Latn"><text for="L2"><span begin="10" end="11">annyeong </span><span begin="11" end="12">sesang</span></text></transliteration></transliterations></iTunesMetadata></metadata></head>
        <body><p begin="1" end="4" itunes:key="L1"><span begin="1" end="2">你好</span><span ttm:role="x-translation" xml:lang="en">Hello</span><span ttm:role="x-translation" xml:lang="id">Halo</span><span ttm:role="x-roman" xml:lang="zh-Latn"><span begin="1" end="1.5">nǐ </span><span begin="1.5" end="2">hǎo</span></span></p>
        <p begin="10" end="14" itunes:key="L2">안녕 세상</p></body></tt>
        """
        let parsed = MusicTTML.parse(xml, duration: 180)
        guard parsed?.plain == "你好\n안녕 세상",
              parsed?.lines.first?["pronunciation"] as? String == "nǐ hǎo",
              (parsed?.lines.first?["translations"] as? [String: String])?["id"] == "Halo",
              parsed?.lines.last?["pronunciation"] as? String == "annyeong sesang",
              (parsed?.lines.last?["translations"] as? [String: String])?["id"] == "Halo dunia" else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Keep inline and header translations/pronunciation attached to their original line without changing sung text"])
        }
        let inlineWords = parsed?.lines.first?["pronunciationWords"] as? [[String: Any]]
        let headerWords = parsed?.lines.last?["pronunciationWords"] as? [[String: Any]]
        guard inlineWords?.count == 2, inlineWords?.last?["start_time"] as? Int == 1500,
              headerWords?.count == 2, headerWords?.last?["end_time"] as? Int == 12000 else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keep provider pronunciation word timestamps separate from sung vocals"])
        }
        let outside = MusicTTML.parse(xml.replacingOccurrences(of: "begin=\"10\" end=\"11\"", with: "begin=\"1\" end=\"2\""), duration: 180)
        guard outside?.lines.last?["pronunciationWords"] == nil else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reject pronunciation timing outside its original lyric line"])
        }
        print("PASS: TTML translations, pronunciation and validated auxiliary word timing")
        guard MusicLyricsTranslation.romanize("Hello world") == nil,
              MusicLyricsTranslation.romanize("안녕하세요") == "annyeonghaseyo",
              MusicLyricsTranslation.romanize("你好世界") == "nǐ hǎo shì jiè",
              MusicLyricsTranslation.romanize("こんにちは世界")?.contains("sekai") == true else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Romanize Korean, Mandarin and Japanese using their own language, and leave Latin text alone"])
        }
        print("PASS: native Japanese, Korean and Mandarin romanization")
        return
    }
    if CommandLine.arguments.contains("--five-sources-only") {
        func lookup(_ title: String) async throws -> MusicLyricsProvider.Record? {
            let track = MusicLyricsProvider.Track(["title": title, "artist": "Artist", "album": "Album", "duration": 180.0])!
            return try await provider.lookup(track).record
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        for (title, source, timing) in [
            ("Priority lines", "Better Lyrics", 1),
            ("Priority words", "Better Lyrics", 2),
            ("Priority NetEase", "NetEase", 1),
            ("Priority LRCLIB", "LRCLIB", 1),
            ("Priority lrcmux", "lrcmux (KuGou)", 1),
            ("Priority NetEase words", "NetEase", 2),
            ("Priority LRCLIB words", "LRCLIB", 2),
            ("Priority lrcmux words", "lrcmux (KuGou)", 2)
        ] {
            let result = try await lookup(title)
            try require(result?.source == source && result?.timingQuality == timing,
                        "\(title): expected \(source) with timing quality \(timing), got \(result?.source ?? "none")")
        }
        let better = try await lookup("Better words")
        try require(better?.source == "Better Lyrics" && better?.timingQuality == 2,
                    "Better Lyrics word timing must participate and improve existing line timing")
        let outside = try await lookup("Better out of range")
        try require(outside?.source == "Better Lyrics" && outside?.timingQuality == 2,
                    "Out-of-range NetEase word times must not suppress valid Better Lyrics timing")
        let hosts = LyricsTransport.lock.withLock { Set(LyricsTransport.requests.compactMap { $0.url?.host }) }
        try require(hosts.isSuperset(of: ["music.163.com", "lrclib.net", "api.amll.dev", "api.betterlyrics.org", "api.lrcmux.dev"]),
                    "Every source must participate even after word timing was found")
        let mux = try await lookup("Mux words")
        try require(mux?.source == "lrcmux (KuGou)" && mux?.timingQuality == 2,
                    "lrcmux must preserve word timing and explicitly reported provider attribution")
        let words = mux?.lyricsFileLines.first?["words"] as? [[String: Any]]
        try require(words?.first?["word"] as? String == "Hello " && words?.first?["start_time"] as? Int == 1000,
                    "lrcmux must preserve text spacing and millisecond timestamps")
        for title in ["Mux wrong version", "Mux wrong artist", "Mux invalid words"] {
            let result = try await lookup(title)
            try require(result?.source == "NetEase" && result?.timingQuality == 1,
                        "\(title) must preserve the valid line-timed result")
        }
        let miss = try await lookup("Better miss")
        try require(miss?.source == "lrcmux (KuGou)" && miss?.timingQuality == 2,
                    "An anonymous Better Lyrics cache miss must not block another word-timed source")
        let cached = try await lookup("Better words")
        try require(cached?.source == "Better Lyrics", "A miss for one song must not disable cached Better Lyrics songs")
        let seconds = MusicTTML.parse("<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1s' end='3s'><span begin='1s' end='2s'>Hello</span></p></body></tt>", duration: 180)
        try require(seconds?.lines.first?["time"] as? Int == 1000,
                    "Provider TTML seconds offsets must retain their actual timing")
        print("PASS: five sources, automatic provider priority, timing quality, Better Lyrics cache access, lrcmux validation and attribution")
        return
    }
    if CommandLine.arguments.contains("--metadata-only") {
        let metadata = MusicLyricsProvider.Track(["title": "Metadata only", "artist": "Artist", "duration": 180.0])!
        let result = try await provider.lookup(metadata)
        guard result.record == nil else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "NetEase JSON credit rows without vocals must not be accepted as song lyrics"])
        }
        let plain = MusicLyricsProvider.Track(["title": "Metadata with plain", "artist": "Artist", "duration": 180.0])!
        let actual = try await provider.lookup(plain).record
        guard actual?.plain == "First real line\nSecond real line" else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "NetEase plain text must exclude JSON credits and preserve the real lyric lines"])
        }
        let timed = MusicLyricsProvider.Track(["title": "Metadata with timing", "artist": "Artist", "duration": 180.0])!
        let lines = try await provider.lookup(timed).record
        guard lines?.timingQuality == 1, lines?.yrc.isEmpty == true else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Metadata-only YRC must not override the actual LRC lyric lines"])
        }
        print("PASS: NetEase metadata rejection and readable plain text")
        return
    }
    if CommandLine.arguments.contains("--amll-only") {
        func lookup(_ title: String) async throws -> MusicLyricsProvider.Record? {
            let track = MusicLyricsProvider.Track(["title": title, "artist": "Artist", "duration": 180.0])!
            return try await provider.lookup(track).record
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "LyricsCheck", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let words = try await lookup("AMLL words")
        try require(words?.source == "AMLL" && words?.timingQuality == 2,
                    "AMLL word timing must improve a matching NetEase/LRCLIB line result")
        let first = words?.lyricsFileLines.first
        let timedWords = first?["words"] as? [[String: Any]]
        try require(first?["text"] as? String == "Hello world" && timedWords?.count == 2,
                    "TTML must preserve word spacing and exclude auxiliary vocals and translations")
        try require(timedWords?.first?["start_time"] as? Int == 1000
                    && timedWords?.first?["end_time"] as? Int == 2000
                    && timedWords?.last?["start_time"] as? Int == 2000,
                    "TTML second, minute and hour clocks must preserve millisecond timing")
        for title in ["AMLL malformed", "AMLL entity", "AMLL wrong artist", "AMLL wrong version"] {
            let result = try await lookup(title)
            try require(result?.source == "NetEase" && result?.timingQuality == 1,
                        "\(title) must keep the valid existing synchronized result")
        }
        let standalone = try await lookup("AMLL standalone")
        try require(standalone?.source == "AMLL" && standalone?.synchronized == false
                    && standalone?.plain == "Hello world\nSecond line",
                    "Unverified platform/version matching must offer plain text instead of invented synchronization")
        let cdata = MusicTTML.parse("<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='4'><span begin='1' end='2'><![CDATA[ Hello ]]></span><span begin='2' end='3'>world </span></p></body></tt>", duration: 180)
        try require(cdata?.plain == "Hello world" && (cdata?.lines.first?["words"] as? [[String: Any]])?.count == 2,
                    "TTML must keep CDATA vocals and trim only outer whitespace without losing word timing")
        let recovered = try await lookup("AMLL lyric failure")
        try require(recovered?.source == "AMLL" && recovered?.timingQuality == 2,
                    "A failed NetEase lyric request must retain verified catalog IDs for AMLL")
        let partial = try await lookup("AMLL partial")
        try require(partial?.source == "AMLL" && partial?.timingQuality == 1,
                    "A later failed AMLL candidate must not discard an already valid synchronized result")
        let limited = try await lookup("AMLL busy")
        try require(limited?.source == "NetEase", "AMLL rate limits must preserve synchronized fallbacks")
        let before = LyricsTransport.lock.withLock { LyricsTransport.requests.filter { $0.url?.host == "api.amll.dev" }.count }
        _ = try await lookup("AMLL busy")
        try require(LyricsTransport.lock.withLock { LyricsTransport.requests.filter { $0.url?.host == "api.amll.dev" }.count } == before,
                    "AMLL Retry-After must prevent requests during its cooldown")
        let tooDeep = "<tt xmlns='http://www.w3.org/ns/ttml'><body>" + String(repeating: "<div>", count: 65)
            + "<p begin='1' end='2'>Text</p>" + String(repeating: "</div>", count: 65) + "</body></tt>"
        try require(MusicTTML.parse(tooDeep, duration: 180) == nil, "Excessive XML nesting must be rejected")
        let outOfRange = MusicTTML.parse("<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='999999999999999' end='9999999999999999'>Text</p></body></tt>", duration: 180)
        try require(outOfRange?.plain == "Text" && outOfRange?.lines.isEmpty == true,
                    "Out-of-range timestamps must remain plain text without integer overflow")
        let partialTiming = MusicTTML.parse("<tt xmlns='http://www.w3.org/ns/ttml'><body><p begin='1' end='4'><span begin='1' end='2'>Hello</span> world</p></body></tt>", duration: 180)
        try require(partialTiming?.lines.first?["text"] as? String == "Hello world"
                    && (partialTiming?.lines.first?["words"] as? [[String: Any]])?.isEmpty == true,
                    "Untimed sung text must keep line timing instead of borrowing the previous word's timestamps")
        let ruby = MusicTTML.parse("<tt xmlns='http://www.w3.org/ns/ttml' xmlns:tts='http://www.w3.org/ns/ttml#styling'><body><p begin='1' end='4'><span begin='1' end='2' tts:ruby='container'><span tts:ruby='base'>字</span><span tts:ruby='text'>ji</span></span></p></body></tt>", duration: 180)
        try require(ruby?.plain == "字" && (ruby?.lines.first?["words"] as? [[String: Any]])?.first?["word"] as? String == "字",
                    "Ruby pronunciation annotations must not leak into sung vocals")
        print("PASS: AMLL native API, TTML word timing, spacing, auxiliary text, matching, XML rejection and fallback")
        return
    }
    if CommandLine.arguments.contains("--providers-only") {
        let track = MusicLyricsProvider.Track(["title": "Word timing", "artist": "Artist", "duration": 180.0])!
        let result = try await provider.lookup(track)
        guard result.record?.source == "NetEase", result.record?.timingQuality == 2 else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "NetEase word timing must win over LRCLIB line timing after a blocked legacy search and a line-only matching release"])
        }
        let alternatives = result.dictionary["alternatives"] as? [[String: Any]] ?? []
        guard Set(alternatives.compactMap { $0["source"] as? String }) == ["NetEase", "LRCLIB"] else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Keep matching alternatives so a manual provider choice can override automatic timing quality"])
        }
        guard LyricsTransport.lock.withLock({ LyricsTransport.requests.contains { $0.url?.host == "api.amll.dev" } }) else {
            throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "AMLL must participate even when an earlier provider already has word timing"])
        }
        print("PASS: native word timing selection across matching releases and providers")
        return
    }
    let suite = "MusicLyricsCheck.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let key = "MusicCustomLyricsEnabled"
    let offsetsKey = "MusicLyricsOffsetsByTrackAndSource"
    if CommandLine.arguments.contains("--source-offsets-only") {
        defaults.set(["video:sourceOffsets01": 750], forKey: "MusicLyricsOffsetsByTrack")
    }
    if CommandLine.arguments.contains("--mode-offsets-only") {
        defaults.set(["video:modeOffsets01|source:NetEase": 750], forKey: offsetsKey)
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    if CommandLine.arguments.contains("--language-ui-only") {
        defaults.set(true, forKey: "MusicLyricsShowTranslation")
        defaults.set(["video:languageSongA": ["translate": false, "pronunciation": false]], forKey: "MusicLyricsLanguageByTrack")
    }
    if CommandLine.arguments.contains("--pronunciation-scroll-only") {
        defaults.set(false, forKey: "MusicLyricsShowPronunciation")
    }
    if CommandLine.arguments.contains("--pronunciation-scroll-only") {
        defaults.set(false, forKey: "MusicLyricsShowPronunciation")
    }
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
    webConfiguration.preferences.inactiveSchedulingPolicy = .none
    for key in ["hiddenPageDOMTimerThrottlingEnabled", "pageVisibilityBasedProcessSuppressionEnabled"] {
        let setter = "_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        if webConfiguration.preferences.responds(to: NSSelectorFromString(setter)) {
            webConfiguration.preferences.setValue(false, forKey: key)
        }
    }
    let controller = webConfiguration.userContentController
    lyrics.connect(to: controller)
    let frameCapture = FrameCapture()
    controller.add(frameCapture, contentWorld: .defaultClient, name: "testFrame")
    controller.addUserScript(WKUserScript(source: "if (window !== window.top) webkit.messageHandlers.testFrame.postMessage(0);",
        injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
    let metadata = live ? [CommandLine.arguments[2], CommandLine.arguments[3]]
        : [plainUI ? "Metadata with plain" : "Fixture", "Artist"]
    let duration = live ? Double(CommandLine.arguments[4])! : 180
    let literal = String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)!
    if CommandLine.arguments.contains("--media-session") || live || plainUI {
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
            return Math.abs(line.top + line.height / 2 - viewport.top - scroll.clientHeight / 2) < 4
                && document.querySelector('#tab-renderer').scrollTop === 0;
        };
        window.fetch = () => { throw new Error('Lyrics must use native networking'); };
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    lyrics.apply(to: controller)
    lyrics.apply(to: controller)
    let scriptCount = controller.userScripts.count
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: webConfiguration)
    // Keep the WebKit fixture rendering when the host app covers its window.
    func setOcclusionDetection(_ enabled: Bool) {
        guard web.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return }
        web.setValue(enabled, forKey: "windowOcclusionDetectionEnabled")
    }
    setOcclusionDetection(false)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web
    lyrics.attach(to: web)
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
        let state = try? await js("JSON.stringify({source:document.querySelector('.lyrics-source')?.textContent, lines:document.querySelectorAll('.lyrics-line').length, animations:document.querySelector('#tab-renderer')?.getAnimations().map(animation => ({state:animation.playState,time:animation.currentTime})), visible:document.visibilityState, pageFocused:document.hasFocus(), focused:document.activeElement?.className, focusWithin:document.activeElement?.parentElement?.matches(':focus-within'), opacity:document.activeElement && getComputedStyle(document.activeElement).opacity, layout:window.beforeWeightChange && [...document.querySelectorAll('.lyrics-line')].map((row,index) => ({before:beforeWeightChange[index], height:row.offsetHeight, weight:getComputedStyle(row).fontWeight, color:getComputedStyle(row).color, current:row.classList.contains('is-current')}))})")
        throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(reason); notice: \(notice ?? "missing"); state: \(state ?? "missing")"])
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
    func expectSavedOffset(_ value: Int?, for identity: String, source: String = "NetEase") async throws {
        let key = "\(identity)|source:\(source)"
        for _ in 0..<100 {
            if lyrics.trackOffsets[key] == value { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "LyricsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected offset \(String(describing: value)) for \(key), found \(String(describing: lyrics.trackOffsets[key]))"])
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
    func snapshot(_ name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["MUSIC_LYRICS_SNAPSHOTS"] else { return }
        let image = try await web.takeSnapshot(configuration: nil)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
    if CommandLine.arguments.contains("--pause-ui-only") {
        try await expect("!!document.querySelector('ytmusic-player-bar .title') && !!document.querySelector('.lyrics-line')", "Wait for fixture page and lyrics")
        try await changeTrack("Pause demo")
        try await expect("document.querySelector('.lyrics-source').textContent.includes('Better Lyrics')", "Load timed pause fixture")
        func seekPause(_ seconds: Double) async throws {
            _ = try await js("fixtureTime = \(seconds); document.querySelector('video').dispatchEvent(new Event('seeking')); null")
        }
        _ = try await js("document.body.style.cssText = 'margin:24px;background:#030303;color:#fff;font:14px Arial,sans-serif'; document.querySelector('#tab-renderer').style.width = '280px'; null")
        try await seekPause(5)
        try await expect("document.querySelectorAll('.lyrics-pause:not([hidden])').length === 1", "Show intro pause")
        try await expect("(() => { const row = document.querySelector('.lyrics-pause:not([hidden])').getBoundingClientRect(); const view = document.querySelector('.lyrics-scroll').getBoundingClientRect(); return Math.abs(row.top + row.height / 2 - view.top - view.height / 2) < 4; })()", "Center intro even when the first lyric wraps tall")
        try await seekPause(10)
        try await expect("!document.querySelector('.lyrics-pause:not([hidden])')", "Hide pause at vocal start")
        try await seekPause(15)
        try await expect("document.querySelectorAll('.lyrics-pause:not([hidden])').length === 1 && document.querySelectorAll('.lyrics-line').length === 3", "Show known middle gap without changing lyric indices")
        try await seekPause(23.5)
        try await expect("document.querySelector('.lyrics-pause:not([hidden]) span').style.opacity === '1'", "Fill first dot during final countdown")
        try await expect("(() => { const row = document.querySelector('.lyrics-pause:not([hidden])').getBoundingClientRect(); const view = document.querySelector('.lyrics-scroll').getBoundingClientRect(); return Math.abs(row.top + row.height / 2 - view.top - view.height / 2) < 4; })()", "Center the active pause indicator")
        try await snapshot("lyrics-pause-countdown")
        try await seekPause(25)
        try await expect("!document.querySelector('.lyrics-pause:not([hidden])') && document.querySelector('.lyrics-line.is-current').textContent.includes('Next vocal')", "Resume correct lyric at boundary")
        try await seekPause(29)
        try await expect("!document.querySelector('.lyrics-pause:not([hidden])')", "Skip short gaps")
        try await seekPause(40)
        try await expect("!document.querySelector('.lyrics-pause:not([hidden])')", "No countdown without another vocal")
        try await changeTrack("Fixture")
        try await expect("document.querySelector('.lyrics-source').textContent.includes('NetEase')", "Return to start-only LRC")
        try await seekPause(6)
        try await expect("!document.querySelector('.lyrics-pause:not([hidden])')", "Do not guess LRC vocal endings")
        print("PASS: intro, known gaps, countdown, seeks, boundaries, short gaps and LRC fallback")
        return
    }
    if CommandLine.arguments.contains("--language-ui-only") {
        try await expect("!!document.querySelector('.lyrics-translate-button') && !!document.querySelector('.lyrics-pronunciation-button')", "Show separate translation and pronunciation controls")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'false' && document.querySelector('.lyrics-pronunciation-button').getAttribute('aria-pressed') === 'true' && document.querySelector('.lyrics-pronunciation-button').hidden", "Pronunciation defaults globally on but stays hidden for Latin lyrics; translation starts off")
        try await selectVersion("languageSongA")
        try await changeTrack("Language demo")
        try await expect("document.querySelector('.lyrics-source')?.textContent.includes('Better Lyrics') === true && !document.querySelector('.lyrics-pronunciation-button').hidden", "Non-Latin lyrics reveal pronunciation")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'false'", "A new song must not inherit translation")
        try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].map(node => node.textContent).join('|') === 'ashita wa hareru|hamkke georeoyo|yì qǐ kàn xīng xing'", "Pronunciation works without starting translation")
        try await expect("document.querySelector('.lyrics-language-select').disabled && document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'false'", "Pronunciation does not require translation languages")
        _ = try await js("document.querySelector('.lyrics-settings-button').click(); null")
        try await expect("!document.querySelector('.lyrics-language-select').disabled", "Gear exposes language selection")
        _ = try await js("document.querySelector('.lyrics-language-select').value = 'id'; document.querySelector('.lyrics-language-select').dispatchEvent(new Event('change')); null")
        _ = try await js("document.querySelector('.lyrics-translate-button').click(); null")
        try await expect("[...document.querySelectorAll('.lyrics-translation')].map(node => node.textContent).join('|') === 'Besok langit akan cerah|Mari berjalan bersama|Bersama melihat bintang'", "Translation works independently beside pronunciation")
        try await expect("document.querySelectorAll('.lyrics-seek .lyrics-word').length === 3", "Auxiliary text preserves original word timing")
        try await expect("document.querySelector('.lyrics-line.is-current .lyrics-pronunciation .lyrics-word.is-current')?.textContent === 'hamkke'", "Provider pronunciation follows its own timed word")
        _ = try await js("fixtureTime = 15; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("document.querySelector('.lyrics-line.is-current .lyrics-pronunciation .lyrics-word.is-current')?.textContent === 'georeoyo'", "Advance pronunciation highlighting with playback")
        _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('timeupdate')); window.musicCustomLyrics.translationStatus(-1, 'download'); null")
        try await expect("!document.querySelector('.lyrics-language-note').textContent.includes('download')", "Ignore stale progress from old translation requests")

        _ = try await js("""
            document.body.style.cssText = 'margin:0;background:#1d2228;color:white;font-family:-apple-system,BlinkMacSystemFont,sans-serif';
            document.querySelector('ytmusic-player-bar').style.cssText = 'display:block;padding:24px;font-size:18px;font-weight:600';
            document.querySelector('.byline').style.cssText = 'display:block;font-size:13px;font-weight:400;margin-top:6px';
            document.querySelectorAll('.byline a').forEach(link => link.style.color = '#bfc4ca');
            document.querySelector('video').style.display = 'none';
            document.querySelector('ytmusic-player-page').style.display = 'block';
            document.querySelector('#tab-renderer').style.cssText = 'height:450px;width:520px;max-width:100%;margin:0 auto';
            document.querySelector('[role=tablist]').style.cssText = 'display:flex;justify-content:center;gap:24px;padding:12px';
            null;
            """)
        _ = try await js("""
            window.languageHandler = webkit.messageHandlers.musicLyricsLanguage;
            window.originalLanguagePost = languageHandler.postMessage.bind(languageHandler);
            languageHandler.postMessage = message => message.action === 'translate'
                ? new Promise((resolve, reject) => { window.fixtureTranslation = {token: message.token, resolve, reject}; })
                : originalLanguagePost(message);
            window.translationIsSpinning = () => {
                const button = document.querySelector('.lyrics-translate-button');
                const spinner = button.querySelector('.lyrics-translation-spinner');
                return button.getAttribute('aria-busy') === 'true' && !!spinner
                    && getComputedStyle(spinner).display !== 'none' && getComputedStyle(spinner).animationName !== 'none';
            };
            document.querySelector('.lyrics-language-select').value = 'fr';
            document.querySelector('.lyrics-language-select').dispatchEvent(new Event('change'));
            null;
            """)
        try await expect("!!window.fixtureTranslation && translationIsSpinning()", "Show a translation spinner while checking languages and awaiting native translation")
        _ = try await js("window.musicCustomLyrics.translationStatus(fixtureTranslation.token, 'download'); null")
        try await expect("translationIsSpinning() && document.querySelector('.lyrics-language-note').textContent.includes('download')", "Keep spinning while waiting for the language download")
        try await snapshot("lyrics-language-busy");
        _ = try await js("document.querySelector('#tab-renderer').style.width = '280px'; null")
        try await snapshot("lyrics-language-busy-narrow");
        _ = try await js("document.querySelector('#tab-renderer').style.width = '520px'; null")
        _ = try await js("window.musicCustomLyrics.translationStatus(fixtureTranslation.token, 'translating'); null")
        try await expect("translationIsSpinning() && document.querySelector('.lyrics-language-note').textContent.includes('Translating')", "Keep spinning during translation")
        _ = try await js("fixtureTranslation.resolve({texts:['Tomorrow will be clear','Walk together','Watch the stars together']}); null")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-busy') === 'false' && getComputedStyle(document.querySelector('.lyrics-translation-spinner')).display === 'none'", "Stop the spinner when translation completes")
        _ = try await js("document.querySelector('.lyrics-language-select').value = 'ko'; document.querySelector('.lyrics-language-select').dispatchEvent(new Event('change')); null")
        try await expect("translationIsSpinning()", "Start a new spinner for a different target language")
        _ = try await js("document.querySelector('.lyrics-translate-button').click(); fixtureTranslation.resolve({texts:['Late translation']}); null")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-busy') === 'false' && getComputedStyle(document.querySelector('.lyrics-translation-spinner')).display === 'none' && [...document.querySelectorAll('.lyrics-translation')].every(node => node.hidden)", "Turning translation off stops the spinner and ignores a late result")
        _ = try await js("document.querySelector('.lyrics-translate-button').click(); null")
        try await expect("translationIsSpinning()", "Allow translation to start again after cancellation")
        _ = try await js("fixtureTranslation.reject(new Error('Fixture unavailable')); null")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-busy') === 'false' && document.querySelector('.lyrics-language-note').textContent.includes('unavailable')", "Stop the spinner when translation fails")
        _ = try await js("languageHandler.postMessage = originalLanguagePost; document.querySelector('.lyrics-language-select').value = 'id'; document.querySelector('.lyrics-language-select').dispatchEvent(new Event('change')); null")
        try await expect("document.querySelector('.lyrics-translation')?.textContent === 'Besok langit akan cerah' && document.querySelector('.lyrics-translate-button').getAttribute('aria-busy') === 'false'", "Restore source translations after checking loading states")

        try await expect("document.querySelector('#tab-renderer').getAnimations().length === 0 && document.fonts.status === 'loaded'", "Finish lyric transitions before inspecting controls")
        _ = try await web.callAsyncJavaScript("await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return null;", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await snapshot("lyrics-language-menu")
        _ = try await js("document.querySelector('#tab-renderer').style.width = '280px'; null")
        try await expect("document.querySelector('.lyrics-settings-panel').getBoundingClientRect().right <= document.querySelector('#tab-renderer').getBoundingClientRect().right", "Gear language controls fit narrow panels")
        try await snapshot("lyrics-language-narrow")
        _ = try await js("document.querySelector('#tab-renderer').style.width = '520px'; document.querySelector('.lyrics-settings-panel .lyrics-close-button').click(); null")
        try await snapshot("lyrics-three-lines")
        try await selectVersion("languageSongB")
        try await changeTrack("Fixture")
        try await expect("document.querySelector('.lyrics-seek')?.textContent === 'First line' && document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'false' && document.querySelector('.lyrics-pronunciation-button').hidden && document.querySelector('.lyrics-pronunciation-button').getAttribute('aria-pressed') === 'true'", "A new Latin song resets translation and retains the global pronunciation choice")
        try await selectVersion("languageSongC")
        try await changeTrack("Pronunciation generated")
        try await expect("!document.querySelector('.lyrics-pronunciation-button').hidden && document.querySelector('.lyrics-pronunciation-button').getAttribute('aria-pressed') === 'true' && document.querySelector('.lyrics-pronunciation')?.textContent === 'yoru da' && document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'false'", "Automatically pronounce a different non-Latin song without enabling its translation")
        _ = try await js("document.querySelector('.lyrics-pronunciation-button').click(); null")
        try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => node.hidden)", "Allow pronunciation to be disabled globally")
        try await selectVersion("languageSongA")
        try await changeTrack("Language demo")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'true' && document.querySelector('.lyrics-pronunciation-button').getAttribute('aria-pressed') === 'false' && document.querySelector('.lyrics-translation')?.textContent === 'Besok langit akan cerah' && [...document.querySelectorAll('.lyrics-pronunciation')].every(node => node.hidden)", "Returning to a saved song restores translation and keeps the global pronunciation OFF")
        for _ in 0..<100 {
            if (defaults.object(forKey: "MusicLyricsShowPronunciation") as? Bool) == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await update()
        try await expect("document.querySelector('.lyrics-pronunciation-button')?.getAttribute('aria-pressed') === 'false' && document.querySelector('.lyrics-translate-button')?.getAttribute('aria-pressed') === 'true'", "Global pronunciation OFF and song translation survive renderer restart")
        _ = try await js("document.querySelector('.lyrics-pronunciation-button').click(); null")
        try await expect("[...document.querySelectorAll('.lyrics-pronunciation')].every(node => !node.hidden)", "Restore global pronunciation independently of translation")
        _ = try await js("document.querySelector('.lyrics-translate-button').click(); null")
        try await expect("[...document.querySelectorAll('.lyrics-translation')].every(node => node.hidden) && [...document.querySelectorAll('.lyrics-pronunciation')].every(node => !node.hidden)", "Turning translation off does not disable pronunciation")
        for _ in 0..<100 {
            if defaults.dictionary(forKey: "MusicLyricsLanguageByTrack")?["video:languageSongA"] == nil
                && (defaults.object(forKey: "MusicLyricsShowPronunciation") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await update()
        try await expect("document.querySelector('.lyrics-pronunciation-button')?.getAttribute('aria-pressed') === 'true' && document.querySelector('.lyrics-translate-button')?.getAttribute('aria-pressed') === 'false'", "Remember global pronunciation ON and per-song translation OFF across renderer restart")
        _ = try await js("document.querySelector('.lyrics-pronunciation-button').click(); null")
        for _ in 0..<100 {
            if (defaults.object(forKey: "MusicLyricsShowPronunciation") as? Bool) == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let globalPronunciation = defaults.object(forKey: "MusicLyricsShowPronunciation") as? Bool
        let translationBook = defaults.dictionary(forKey: "MusicLyricsLanguageByTrack")
        guard globalPronunciation == false, translationBook?["video:languageSongA"] == nil,
              translationBook?["video:languageSongC"] == nil else { fatalError("Save pronunciation globally without adding song overrides") }
        print("PASS: separate lyric controls, global pronunciation, per-song translation, spinner lifecycle, CJK visibility, independent updates, reload and narrow layout")
        return
    }
    if CommandLine.arguments.contains("--pronunciation-scroll-only") {
        try await checkPronunciationScrolling(js: js, expect: { value, reason in try await expect(value, reason) }, changeTrack: changeTrack, snapshot: snapshot)
        return
    }
    if CommandLine.arguments.contains("--pronunciation-ui-only") {
        try await expect("!!document.querySelector('.lyrics-pronunciation-button')", "Load lyric controls before changing the test song")
        try await changeTrack("Pronunciation generated")
        try await expect("document.querySelector('.lyrics-source')?.textContent.includes('Better Lyrics') === true && !document.querySelector('.lyrics-pronunciation-button').hidden", "Load non-Latin timed vocals for automatic pronunciation")
        _ = try await js("fixtureTime = 2; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("document.querySelectorAll('.lyrics-pronunciation .lyrics-word').length === 2", "Map generated pronunciation to original word timestamps")
        try await expect("document.querySelector('.lyrics-pronunciation .lyrics-word.is-current')?.textContent === 'yoru'", "Highlight the first generated word")
        _ = try await js("fixtureTime = 4; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("document.querySelector('.lyrics-pronunciation .lyrics-word.is-current')?.textContent === 'da'", "Highlight the next generated word")
        _ = try await js("fixtureTime = 2; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("document.querySelector('.lyrics-pronunciation .lyrics-word.is-current')?.textContent === 'yoru' && !document.querySelectorAll('.lyrics-pronunciation .lyrics-word')[1].classList.contains('is-sung')", "Seeking backwards clears later pronunciation progress")
        try await expect("document.querySelector('.lyrics-translate-button').getAttribute('aria-pressed') === 'false' && document.querySelector('.lyrics-language-select').disabled", "Automatic pronunciation never enables translation or asks for its models")
        try await changeTrack("Latin demo")
        try await expect("document.querySelector('.lyrics-seek')?.textContent === 'Café déjà vu 👩‍🎤 123' && document.querySelector('.lyrics-pronunciation-button').hidden", "Accented Latin, digits and emoji do not reveal pronunciation")
        print("PASS: generated pronunciation karaoke, forward/backward seeking, independent translation and non-Latin visibility")
        return
    }
    if CommandLine.arguments.contains("--blank-lines-only") {
        try await expect("!!document.querySelector('.lyrics-line')", "Load initial lyrics before checking blank cues")
        try await selectVersion("blankLines01")
        try await changeTrack("Blank lyric lines")
        try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-source').textContent === 'LRCLIB'", "Load LRCLIB Lyricsfile with blank timing cues")
        try await expect("document.querySelectorAll('.lyrics-line').length === 2 && document.querySelectorAll('.lyrics-align').length === 2", "Empty, whitespace-only and invisible-only cues must not create lyric rows or sync buttons")
        try await expect("document.querySelectorAll('.lyrics-seek')[1].textContent === 'Second 👩‍🎤 line'", "Preserve joiners inside visible lyric text")
        _ = try await js("fixtureTime = 12; window.lastSeek = null; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second 👩‍🎤 line'", "Filtered rows must keep highlighting the correct timestamp")
        _ = try await js("document.querySelector('.lyrics-align').click(); null")
        try await expectSavedOffset(11000, for: "video:blankLines01", source: "LRCLIB")
        try await expect("lastSeek === null", "Sync a visible line without seeking")
        _ = try await js("document.querySelectorAll('.lyrics-seek')[1].click(); null")
        try await expect("lastSeek === 21", "Removing blank rows must preserve seeking and alignment of the remaining lines")
        try await changeTrack("Only blank lyrics")
        try await expect("document.querySelector('.lyrics-scroll').hidden && document.querySelectorAll('.lyrics-align').length === 0 && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'", "A provider with only blank cues must preserve native lyrics without empty actions")
        print("PASS: blank and invisible lyric rejection, preserved emoji joiners, highlight, sync, seeking and native fallback")
        return
    }
    if CommandLine.arguments.contains("--provider-choice-only") {
        try await expect("!!document.querySelector('.lyrics-line')", "Load initial lyrics before choosing a provider")
        try await changeTrack("Credit fallback")
        try await expect("document.querySelector('.lyrics-seek')?.textContent === 'Fallback first' && document.querySelector('.lyrics-offset-source').textContent === 'LRCLIB'", "A credit-only automatic winner must not hide another provider's usable lyrics")
        try await changeTrack("Fixture")
        try await expect("document.querySelector('.lyrics-seek')?.textContent === 'First line'", "Restore normal lyrics before choosing a provider")
        try await selectVersion("providerChoice01")
        try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-provider-select')?.options.length === 3", "Offer Automatic and every matching provider after the new song has loaded")
        _ = try await js("document.querySelector('.lyrics-settings-button').click(); null")
        let requests = LyricsTransport.lock.withLock { LyricsTransport.requests.count }
        _ = try await js("const select = document.querySelector('.lyrics-provider-select'); select.value = 'LRCLIB'; select.dispatchEvent(new Event('change')); null")
        try await expect("document.querySelector('.lyrics-seek')?.textContent === 'Fallback first' && !document.querySelector('.lyrics-settings-panel').hidden", "Choosing LRCLIB must immediately replace the lyrics and keep settings open")
        try await expect("document.querySelector('.lyrics-provider-note').textContent.includes('Saved')", "Explain that the provider is remembered for this song")
        assert(LyricsTransport.lock.withLock { LyricsTransport.requests.count } == requests, "Switch providers without making another network request")
        for _ in 0..<100 {
            if defaults.dictionary(forKey: "MusicLyricsProvidersByTrack")?["video:providerChoice01"] as? String == "LRCLIB" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        assert(defaults.dictionary(forKey: "MusicLyricsProvidersByTrack")?["video:providerChoice01"] as? String == "LRCLIB")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(10, for: "video:providerChoice01", source: "LRCLIB")
        try await selectVersion("providerChoice02")
        try await expect("document.querySelector('.lyrics-offset-source').textContent === 'NetEase' && document.querySelector('.lyrics-provider-select').value === ''", "A provider choice must apply only to its song")
        try await selectVersion("providerChoice01")
        try await expect("document.querySelector('.lyrics-provider-select').value === 'LRCLIB' && document.querySelector('.lyrics-offset-input').value === '0.01'", "Returning to a song restores its provider and that provider's offset")
        _ = try await js("document.documentElement.dataset.beforeProviderReload = 'true'; null")
        web.loadHTMLString(pageHTML, baseURL: URL(string: "https://music.youtube.com/watch?v=providerChoice01"))
        try await expect("!document.documentElement.dataset.beforeProviderReload && document.querySelector('.lyrics-provider-select')?.value === 'LRCLIB' && document.querySelector('.lyrics-seek')?.textContent === 'Fallback first'", "Remember the provider across a full document reload")
        _ = try await js("document.querySelector('[data-reset]').click(); null")
        try await expect("document.querySelector('.lyrics-provider-select').value === 'LRCLIB' && document.querySelector('.lyrics-offset-input').value === '0'", "Reset timing without changing the saved provider")
        _ = try await js("document.querySelector('.lyrics-provider-select').value = ''; document.querySelector('.lyrics-provider-select').dispatchEvent(new Event('change')); null")
        try await expect("document.querySelector('.lyrics-offset-source').textContent === 'NetEase' && document.querySelector('.lyrics-offset-input').value === '0'", "Automatic restores the best match with its own offset")
        try await changeTrack("Better words")
        try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-source').textContent === 'Better Lyrics'", "Load the provider before saving a preference")
        _ = try await js("document.querySelector('.lyrics-provider-select').value = 'LRCLIB'; document.querySelector('.lyrics-provider-select').dispatchEvent(new Event('change')); null")
        try await expect("document.querySelector('.lyrics-seek')?.textContent === 'Fallback first' && document.querySelectorAll('.lyrics-word').length === 0", "A manual line-timed provider must override the automatic word-timed winner")
        _ = try await js("document.querySelector('.lyrics-provider-select').value = 'Better Lyrics'; document.querySelector('.lyrics-provider-select').dispatchEvent(new Event('change')); null")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album changed'; null")
        try await expect("document.querySelector('.lyrics-offset-source').textContent === 'NetEase' && document.querySelector('.lyrics-provider-note').textContent.includes('unavailable')", "An unavailable saved provider must explain the fallback and allow recovery")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album'; null")
        try await expect("document.querySelector('.lyrics-provider-select').value === 'Better Lyrics' && document.querySelector('.lyrics-offset-source').textContent === 'Better Lyrics'", "A temporarily unavailable provider must keep its saved preference")
        _ = try await js("document.querySelector('.lyrics-provider-select').value = ''; document.querySelector('.lyrics-provider-select').dispatchEvent(new Event('change')); null")
        _ = try await js("webkit.messageHandlers.musicLyricsProvider.postMessage({trackKey:'video:bad/id', source:'LRCLIB'}); webkit.messageHandlers.musicLyricsProvider.postMessage({trackKey:'video:bad', source:'Unknown'}); null")
        try await Task.sleep(for: .milliseconds(100))
        assert(defaults.object(forKey: "MusicLyricsProvidersByTrack") == nil, "Automatic clears saved choices and invalid provider messages must not persist")
        print("PASS: manual providers, local switching, per-song defaults, reload, source offsets, unavailable fallback and validation")
        return
    }
    if CommandLine.arguments.contains("--align-ui-only") {
        try await expect("!!document.querySelector('.lyrics-line')", "Load initial lyrics before aligning")
        try await selectVersion("alignTiming01")
        try await expect("!!document.querySelector('.lyrics-align')", "Offer a separate align action on timed lyric lines")
        _ = try await js("fixtureTime = 12; window.lastSeek = null; document.querySelector('.lyrics-align').click(); null")
        try await expect("lastSeek === null && document.querySelector('.lyrics-offset-input').value === '11' && document.querySelector('.lyrics-line.is-current')?.textContent === 'First line'", "Align the line to playback without seeking or silently clamping to ten seconds")
        try await expectSavedOffset(11000, for: "video:alignTiming01")
        _ = try await js("document.querySelectorAll('.lyrics-seek')[1].click(); null")
        try await expect("lastSeek === 21", "Seeking another line includes the aligned offset")
        _ = try await js("fixtureTime = 4.5; lastSeek = null; document.querySelectorAll('.lyrics-align')[1].click(); null")
        try await expect("lastSeek === null && document.querySelector('.lyrics-offset-input').value === '-5.5'", "Realignment calculates a fresh offset instead of accumulating the previous one")
        try await expectSavedOffset(-5500, for: "video:alignTiming01")
        try await update()
        try await expect("document.querySelector('.lyrics-offset-input').value === '-5.5'", "Alignment survives a renderer restart")
        _ = try await js("fixtureTime = NaN; document.querySelector('.lyrics-align').click(); null")
        try await expectSavedOffset(-5500, for: "video:alignTiming01")
        _ = try await js("fixtureTime = 12; document.querySelector('[data-reset]').click(); null")
        try await expectSavedOffset(nil, for: "video:alignTiming01")
        try await expect("document.querySelector('#tab-renderer').getAnimations().length === 0", "Finish revealing lyrics before inspecting their layout")
        _ = try await js("document.body.style.cssText = 'margin:24px;background:#030303;color:#fff;font:14px Arial,sans-serif'; null")
        for width in [280, 520] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(web)
            try await expect("document.hasFocus()", "Activate the test page before checking keyboard focus")
            _ = try await js("document.querySelector('#tab-renderer').style.width = '\(width)px'; document.querySelectorAll('.lyrics-align')[1].focus({preventScroll:true}); null")
            try await expect("document.activeElement.classList.contains('lyrics-align') && getComputedStyle(document.activeElement).opacity === '1'", "Reveal alignment on keyboard focus at \(width)px")
            let dimensions = try await js("JSON.stringify({width:document.querySelector('.lyrics-scroll').clientWidth, content:document.querySelector('.lyrics-scroll').scrollWidth})")
            try await expect("document.querySelector('.lyrics-scroll').scrollWidth <= document.querySelector('.lyrics-scroll').clientWidth", "No horizontal overflow at \(width)px: \(dimensions ?? "unknown")")
            try await snapshot("align-\(width)")
            _ = try await js("document.querySelector('.lyrics-settings-button').click(); null")
            try await expect("document.querySelector('.lyrics-settings-panel').getBoundingClientRect().bottom <= document.querySelector('#tab-renderer').getBoundingClientRect().bottom", "Settings must fit the lyrics viewport")
            try await snapshot("providers-\(width)")
            _ = try await js("document.querySelector('.lyrics-settings-button').click(); null")
        }
        print("PASS: one-click alignment, both offset directions, seeking, persistence, reset, invalid clocks and keyboard layout")
        return
    }
    func checkFeedback() async throws {
        try await expect("!!document.querySelector('.lyrics-line.is-current') && !document.hidden", "Load visible lyrics before checking motion feedback")
        _ = try await js("""
            document.body.style.cssText = 'margin:24px;background:#030303;color:#fff;font:14px Arial,sans-serif';
            document.querySelector('#tab-renderer').style.width = '360px';
            document.querySelector('#native-lyrics').style.cssText = 'padding:24px 16px;font-size:18px';
            document.querySelector('#native-lyrics').textContent = 'Native lyrics remain readable while searching';
            null
            """)
        try await changeTrack("Slow")
        try await expect("""
            (() => {
                const spinner = document.querySelector('.lyrics-spinner');
                return spinner?.getAttribute('aria-hidden') === 'true'
                    && getComputedStyle(spinner).animationName !== 'none'
                    && document.querySelector('.lyrics-scroll').getAttribute('aria-busy') === 'true'
                    && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none';
            })()
            """, "Show animated, accessible loading feedback alongside native lyrics")
        try await snapshot("loading")
        try await expect("""
            !document.querySelector('.lyrics-scroll').hidden && lineIsCentered()
                && document.querySelector('#tab-renderer').getAnimations().some(animation => animation.playState === 'running')
            """, "Position the active line before the lyrics fade in", seconds: 6)
        try await expect("document.querySelector('#tab-renderer').getAnimations().length === 0", "Finish the lyric reveal")
        try await snapshot("synced")
        try await changeTrack("HTTP error")
        try await expect("!!document.querySelector('.lyrics-info-button')", "Show provider failure feedback")
        for width in [280, 360, 520] {
            _ = try await js("document.querySelector('#tab-renderer').style.width = '\(width)px'; null")
            try await expect("""
                (() => {
                    const notice = document.querySelector('#music-custom-lyrics').getBoundingClientRect();
                    const text = document.querySelector('.lyrics-message-text').getBoundingClientRect();
                    const actions = document.querySelector('.lyrics-message-actions').getBoundingClientRect();
                    return Math.abs(text.top + text.height / 2 - actions.top - actions.height / 2) < 2
                        && actions.right <= notice.right && notice.height <= 80;
                })()
                """, "Keep feedback and actions together without excess space at \(width)px")
            try await snapshot("unavailable-\(width)")
        }
        _ = try await js("document.querySelector('.lyrics-info-button').click(); null")
        try await snapshot("error-details")
        _ = LyricsTransport.lock.withLock { LyricsTransport.recovered.insert("HTTP error") }
        _ = try await js("const retry = document.querySelector('.lyrics-message button:not(.lyrics-info-button)'); retry.focus(); retry.click(); null")
        try await expect("document.activeElement === document.querySelector('.lyrics-scroll') && !document.querySelector('.lyrics-scroll').hidden",
                         "Keep keyboard focus usable when retry is replaced by lyrics")
        try await changeTrack("Slow")
        try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Reuse a cached result after retry")
        let fadingOut = "document.querySelector('#tab-renderer').getAnimations().some(animation => animation.effect.getKeyframes().at(-1).opacity === '0')"
        try await changeTrack("Interrupted track fade")
        try await expect(fadingOut, "Begin fading the outgoing lyrics before changing track")
        try await changeTrack("Better words")
        try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && document.querySelector('.lyrics-source').textContent.includes('Better Lyrics')",
                         "An interrupted fade must display only the latest song's source")
        try await changeTrack("Interrupted tab fade")
        try await expect(fadingOut, "Begin fading the outgoing lyrics before hiding the tab")
        _ = try await js("document.querySelectorAll('[role=tab]')[1].setAttribute('aria-selected','false'); null")
        try await expect("document.querySelector('#tab-renderer').getAnimations().length === 0 && getComputedStyle(document.querySelector('#tab-renderer')).opacity === '1' && getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none'",
                         "Cancel a running fade without leaving another tab transparent")
        try await changeTrack("Recovered")
        _ = try await js("document.querySelectorAll('[role=tab]')[1].setAttribute('aria-selected','true'); null")
        try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && lineIsCentered()",
                         "Changing tracks and tabs must not reveal stale lyrics")
        try await expect("document.querySelector('#tab-renderer').getAnimations().length === 0", "Finish the last reveal before testing reduced motion")
        _ = try await js("""
            fixtureReduceMotion = true;
            window.reducedReveal = null;
            const revealObserver = new MutationObserver(() => {
                if (!document.querySelector('.lyrics-scroll').hidden) {
                    reducedReveal = lineIsCentered() && document.querySelector('#tab-renderer').getAnimations().length === 0;
                    revealObserver.disconnect();
                }
            });
            revealObserver.observe(document.querySelector('.lyrics-scroll'), {attributes:true, attributeFilter:['hidden']});
            null
            """)
        try await changeTrack("Reduced motion feedback")
        try await expect("reducedReveal === true", "Reduced Motion must reveal centered lyrics without a fade")
        _ = try await js("fixtureReduceMotion = false; null")
        try await changeTrack("Occluded fade")
        try await expect(fadingOut, "Begin a transition before hiding the window")
        setOcclusionDetection(true)
        window.orderOut(nil)
        try await expect("document.hidden && !document.querySelector('.lyrics-scroll').hidden && document.querySelector('#tab-renderer').getAnimations().length === 0",
                         "Hiding the window must finish the swap without waiting for a suspended animation")
        window.orderFrontRegardless()
        setOcclusionDetection(false)
        try await expect("!document.hidden", "Show the window before starting another lookup")
        try await changeTrack("Background slow")
        try await expect("!!document.querySelector('.lyrics-spinner') && document.querySelector('.lyrics-scroll').hidden", "Start a lookup before hiding the window")
        setOcclusionDetection(true)
        window.orderOut(nil)
        try await expect("document.hidden && !document.querySelector('.lyrics-scroll').hidden && document.querySelector('#tab-renderer').getAnimations().length === 0",
                         "Background results must install lyrics without starting an invisible animation", seconds: 6)
        print("PASS: compact feedback, loading spinner, settled lyric reveal, retry focus and interrupted transitions")
    }
    if CommandLine.arguments.contains("--feedback-ui-only") {
        try await checkFeedback()
        return
    }
    func checkModeOffsets() async throws {
        let song = "mode:song|video:modeOffsets01"
        let video = "mode:video|video:modeOffsets01"
        try await expect("!!document.querySelector('.lyrics-line')", "Load lyrics before checking playback modes")
        try await selectVersion("modeOffsets01")
        try await expect("document.querySelector('.lyrics-offset-input').value === '0.75'", "Retain old adjustments when playback mode is unidentified")
        _ = try await js("""
            const toggle = document.createElement('ytmusic-av-toggle');
            toggle.setAttribute('playback-mode', 'ATV_PREFERRED');
            document.querySelector('ytmusic-player-page').prepend(toggle);
            null
            """)
        try await expect("document.querySelector('.lyrics-offset-input').value === '0' && document.querySelector('.lyrics-offset-scope')?.textContent === 'Saved for Song mode'",
                         "Song mode must not guess which version an unclassified offset belongs to")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(10, for: song)
        _ = try await js("document.querySelector('ytmusic-av-toggle').setAttribute('playback-mode', 'OMV_PREFERRED'); document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expect("document.querySelector('.lyrics-offset-input').value === '0' && document.querySelector('.lyrics-offset-scope').textContent === 'Saved for Video mode'",
                         "A mode-only switch with identical media ID, duration and title must restore Video timing")
        try await expectSavedOffset(10, for: song)
        _ = try await js("document.querySelector('[data-offset=\"-10\"]').click(); document.querySelector('[data-offset=\"-10\"]').click(); document.querySelector('.lyrics-seek').click(); null")
        try await expectSavedOffset(-20, for: video)
        try await expect("lastSeek === 0.98", "Video seeking must use only its own adjustment")
        _ = try await js("document.querySelector('ytmusic-av-toggle').setAttribute('playback-mode', 'ATV_PREFERRED'); null")
        try await expect("document.querySelector('.lyrics-offset-input').value === '0.01'", "Returning to Song must restore Song timing")
        try await changeTrack("Better words")
        try await expect("document.querySelector('.lyrics-offset-source').textContent === 'Better Lyrics' && document.querySelector('.lyrics-offset-input').value === '0'", "A different lyric source must not inherit the mode's previous source offset")
        try await changeTrack("Fixture")
        try await expect("document.querySelector('.lyrics-offset-source').textContent === 'NetEase' && document.querySelector('.lyrics-offset-input').value === '0.01'", "Returning to the same mode and source must restore its adjustment")
        let songHTML = pageHTML.replacingOccurrences(of: "<ytmusic-player-page>", with: "<ytmusic-player-page><ytmusic-av-toggle playback-mode='ATV_PREFERRED'></ytmusic-av-toggle>")
        _ = try await js("document.documentElement.dataset.beforeModeReload = 'true'; null")
        web.loadHTMLString(songHTML, baseURL: URL(string: "https://music.youtube.com/watch?v=modeOffsets01"))
        try await expect("!document.documentElement.dataset.beforeModeReload && !!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-offset-input').value === '0.01'", "Mode offsets must survive a full document reload")
        _ = try await js("document.querySelector('[data-reset]').click(); null")
        try await expectSavedOffset(nil, for: song)
        try await expectSavedOffset(-20, for: video)
        _ = try await js("document.querySelector('ytmusic-player-page').setAttribute('video-mode', ''); null")
        try await expect("document.querySelector('.lyrics-offset-input').value === '-0.02' && document.querySelector('.lyrics-offset-scope').textContent === 'Saved for Video mode'", "The player's actual video-mode attribute must also restore Video timing")
        try await selectVersion("")
        try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0'", "Mode-aware metadata fallback must not reuse another media identity")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(10, for: #"mode:video|track:["fixture","artist",180]"#)
        _ = try await js("""
            for (const trackKey of ['mode:podcast|video:bad|source:NetEase', 'mode:video|video:bad/id|source:NetEase', 'mode:video|video:bad|source:Unknown']) {
                webkit.messageHandlers.musicLyricsOffset.postMessage({trackKey, milliseconds:250});
            }
            null
            """)
        try await Task.sleep(for: .milliseconds(100))
        assert(lyrics.trackOffsets.count == 3, "Invalid modes, media IDs and sources must not create stored offsets")
        try await expectSavedOffset(750, for: "video:modeOffsets01")
        print("PASS: Song/Video timing isolation, source identity, seeking, reload, reset, metadata fallback, validation and legacy preservation")
    }
    if CommandLine.arguments.contains("--mode-offsets-only") {
        try await checkModeOffsets()
        return
    }
    if CommandLine.arguments.contains("--timing-input-only") {
        try await expect("!!document.querySelector('.lyrics-line')", "Load lyrics before editing timing")
        try await selectVersion("timingInput01")
        try await expect("!document.querySelector('.lyrics-toolbar').hidden && !document.querySelector('.lyrics-scroll').hidden", "Wait for the selected song's timing controls before editing")
        _ = try await js("document.querySelector('.lyrics-settings-button').click(); null")
        try await expect("document.querySelector('.lyrics-offset-input')?.type === 'number'", "Timing must have an editable numeric field")
        _ = try await js("document.querySelector('[data-offset=\"-10\"]').click(); null")
        try await expectSavedOffset(-10, for: "video:timingInput01")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(nil, for: "video:timingInput01")
        _ = try await js("""
            window.timingInput = document.querySelector('.lyrics-offset-input');
            timingInput.focus();
            timingInput.value = '-6.643';
            timingInput.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true, cancelable:true}));
            null
            """)
        try await expectSavedOffset(-6643, for: "video:timingInput01")
        try await expect("document.querySelector('.lyrics-source').textContent.endsWith('· 6.643 s earlier')", "Manual millisecond precision must appear in the footer")
        _ = try await js("timingInput.focus(); timingInput.value = '2'; timingInput.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true, cancelable:true})); null")
        try await expect("timingInput.value === '-6.643' && !document.querySelector('.lyrics-settings-panel').hidden", "Escape must discard a draft without closing timing settings")
        try await expectSavedOffset(-6643, for: "video:timingInput01")
        for value in ["", "abc", "Infinity", "3600.001", "-3600.001"] {
            _ = try await web.callAsyncJavaScript("""
                timingInput.value = value;
                timingInput.dispatchEvent(new Event('change'));
                return null;
                """, arguments: ["value": value], in: nil, contentWorld: .defaultClient)
            try await expect("!timingInput.checkValidity()", "Invalid manual offsets must be rejected by the numeric field")
            try await expectSavedOffset(-6643, for: "video:timingInput01")
        }
        for (value, milliseconds) in [("1.235", 1235), ("3600", 3600000), ("-3600", -3600000)] {
            _ = try await web.callAsyncJavaScript("""
                timingInput.value = value;
                timingInput.dispatchEvent(new Event('change'));
                return null;
                """, arguments: ["value": value], in: nil, contentWorld: .defaultClient)
            try await expectSavedOffset(milliseconds, for: "video:timingInput01")
        }
        _ = try await js("fixtureTime = 3.217; document.querySelector('.lyrics-align').click(); null")
        try await expectSavedOffset(2217, for: "video:timingInput01")
        try await expect("timingInput.value === '2.217'", "Sync must retain its exact millisecond offset in the editable field")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(2227, for: "video:timingInput01")
        _ = try await js("document.querySelector('[data-reset]').click(); null")
        try await expectSavedOffset(nil, for: "video:timingInput01")
        try await expect("timingInput.value === '0' && !document.querySelector('.lyrics-source').textContent.includes('later')", "Reset must clear the input and footer adjustment")
        _ = try await js("timingInput.value = '-6.643'; timingInput.dispatchEvent(new Event('change')); null")
        try await expectSavedOffset(-6643, for: "video:timingInput01")
        try await update()
        try await expect("document.querySelector('.lyrics-offset-input')?.value === '-6.643'", "Manual timing must survive a renderer restart")
        print("PASS: 10 ms buttons, manual seconds, Enter, Escape, validation, exact Sync precision, reset and persistence")
        return
    }
    if CommandLine.arguments.contains("--source-offsets-only") {
        try await expect("!!document.querySelector('.lyrics-line')", "Load lyrics before checking per-source timing")
        try await selectVersion("sourceOffsets01")
        try await changeTrack("Better words")
        try await expect("document.querySelector('.lyrics-source').textContent.includes('Better Lyrics')", "Load Better Lyrics for a fixed video identity")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from Better Lyrics · Word-by-word'", "Unadjusted lyrics must not show an offset in the footer")
        try await expect("document.querySelector('.lyrics-offset-input').value === '0'", "An old offset with no known provider must not be applied to an arbitrary source")
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'Better Lyrics'", "Timing settings must name the source whose adjustment will be saved")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(10, for: "video:sourceOffsets01", source: "Better Lyrics")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from Better Lyrics · Word-by-word · 0.01 s later'", "The footer must show a positive offset and explain that lyrics appear later")
        try await snapshot("timing-offset-later")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album changed'; null")
        try await expect("document.querySelector('.lyrics-source').textContent.includes('NetEase') && document.querySelector('.lyrics-offset-input').value === '0'", "Another source for the same song must start with its own offset")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from NetEase · Line-by-line'", "Switching sources must clear the previous source's footer offset")
        _ = try await js("document.querySelector('[data-offset=\"-10\"]').click(); document.querySelector('[data-offset=\"-10\"]').click(); null")
        try await expectSavedOffset(-20, for: "video:sourceOffsets01")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from NetEase · Line-by-line · 0.02 s earlier'", "The footer must show a negative offset and explain that lyrics appear earlier")
        window.setContentSize(NSSize(width: 400, height: 500))
        try await expect("innerWidth === 400 && document.querySelector('.lyrics-source').scrollWidth <= document.querySelector('.lyrics-source').clientWidth", "The timing footer must fit a narrow window")
        try await snapshot("timing-offset-earlier-narrow")
        window.setContentSize(NSSize(width: 900, height: 600))
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album'; null")
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'Better Lyrics' && document.querySelector('.lyrics-offset-input').value === '0.01'", "Returning to a source must restore its own saved timing")
        _ = try await js("document.querySelector('.lyrics-seek').click(); null")
        try await expect("lastSeek === 1.01", "Seeking must use the selected source's offset")
        try await update()
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'Better Lyrics' && document.querySelector('.lyrics-offset-input').value === '0.01'", "Source offsets must survive a renderer restart")
        try await expect("document.querySelector('.lyrics-source').textContent.endsWith('· 0.01 s later')", "The footer must restore the saved offset after a renderer restart")
        assert(MusicLyrics(defaults: defaults).trackOffsets["video:sourceOffsets01|source:Better Lyrics"] == 10)
        _ = try await js("document.querySelector('[data-reset]').click(); null")
        try await expectSavedOffset(nil, for: "video:sourceOffsets01", source: "Better Lyrics")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from Better Lyrics · Word-by-word'", "Reset must remove the timing adjustment from the footer")
        try await expectSavedOffset(-20, for: "video:sourceOffsets01")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album changed'; null")
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'NetEase' && document.querySelector('.lyrics-offset-input').value === '-0.02'", "Reset must not erase another source's timing")
        _ = try await js("document.querySelector('[data-reset]').click(); null")
        try await expectSavedOffset(nil, for: "video:sourceOffsets01")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album'; null")
        try await changeTrack("Mux words")
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'lrcmux (KuGou)'", "Aggregators must retain their explicitly reported upstream source identity")
        _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
        try await expectSavedOffset(10, for: "video:sourceOffsets01", source: "lrcmux (KuGou)")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Deezer version'; null")
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'lrcmux (Deezer)' && document.querySelector('.lyrics-offset-input').value === '0'", "Different upstream providers within an aggregator must not share offsets")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album'; null")
        try await expect("document.querySelector('.lyrics-offset-source')?.textContent === 'lrcmux (KuGou)' && document.querySelector('.lyrics-offset-input').value === '0.01'", "Returning to an upstream source must restore its offset")
        _ = try await js("document.querySelector('[data-reset]').click(); null")
        try await expectSavedOffset(nil, for: "video:sourceOffsets01", source: "lrcmux (KuGou)")
        assert(defaults.object(forKey: offsetsKey) == nil, "Resetting all current offsets must remove only the new preference container")
        assert(defaults.dictionary(forKey: "MusicLyricsOffsetsByTrack")?["video:sourceOffsets01"] as? Int == 750,
               "Legacy offsets must remain intact because their original source cannot be inferred")
        print("PASS: song/source timing isolation, upstream providers, restart, seeking, reset and legacy preservation")
        return
    }
    if CommandLine.arguments.contains("--five-ui-only") {
        try await expect("!!document.querySelector('.lyrics-line')", "Load the initial native fixture before changing its track")
        try await changeTrack("Better words")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from Better Lyrics · Word-by-word' && document.querySelectorAll('.lyrics-word').length === 2",
                         "Better Lyrics must use album metadata from the player bar and the existing renderer")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album changed'; null")
        try await expect("document.querySelector('.lyrics-source').textContent.includes('NetEase') && document.querySelector('.lyrics-source').textContent.includes('Line-by-line')",
                         "Album changes must invalidate a previous Better Lyrics cache result")
        _ = try await js("document.querySelector('a[href=\"/browse/MPREfixture\"]').textContent = 'Album'; null")
        try await changeTrack("Mux words")
        try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from lrcmux (KuGou) · Word-by-word'",
                         "lrcmux must display its explicitly reported original provider")
        _ = try await js("fixtureTime = 1.5; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
        try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Hello world' && document.querySelector('.lyrics-word.is-current')?.textContent.trim() === 'Hello'",
                         "lrcmux word timestamps must drive karaoke highlighting")
        _ = try await js("document.querySelectorAll('.lyrics-seek')[1].click(); null")
        try await expect("lastSeek === 10", "lrcmux timestamps must seek in seconds through the existing player")
        try await changeTrack("Syllable wrap")
        try await expect("document.querySelectorAll('.lyrics-word').length === 8", "Load independently timed syllables for the word-wrapping check")
        _ = try await js("""
            fixtureTime = 7.5;
            document.querySelector('video').dispatchEvent(new Event('timeupdate'));
            const button = document.querySelector('.lyrics-seek');
            button.closest('.lyrics-line').style.transform = 'none';
            button.closest('.lyrics-line').style.transition = 'none';
            const syllables = button.querySelectorAll('.lyrics-word');
            const range = document.createRange();
            range.setStart(button, 0);
            range.setEndAfter(syllables[6]);
            window.wrapWidth = range.getBoundingClientRect().width + 1 + button.parentElement.clientWidth - button.clientWidth;
            document.querySelector('.lyrics-lines').style.width = `${wrapWidth}px`;
            null
            """)
        try await expect("""
            (() => {
                const button = document.querySelector('.lyrics-seek');
                const syllables = button.querySelectorAll('.lyrics-word');
                const before = syllables[5].getBoundingClientRect();
                const se = syllables[6].getBoundingClientRect();
                const nang = syllables[7].getBoundingClientRect();
                return Math.abs(se.top - nang.top) < 1 && se.top > before.top + 5
                    && Math.abs(se.left - button.getBoundingClientRect().left) < 2;
            })()
            """, "A complete word must move to the next line rather than wrap between timed syllables")
        try await expect("""
            (() => {
                const list = document.querySelector('.lyrics-lines');
                const syllables = document.querySelectorAll('.lyrics-word');
                for (let width = 200; width <= 500; width += 4) {
                    list.style.width = `${width}px`;
                    if (Math.abs(syllables[6].getBoundingClientRect().top - syllables[7].getBoundingClientRect().top) > 1) return false;
                }
                list.style.width = `${wrapWidth}px`;
                return true;
            })()
            """, "Timed syllables of one word must remain together across panel widths")
        try await expect("document.querySelector('.lyrics-seek').textContent === 'Sedang tak mudah bertemu rasa senang' && document.querySelector('.lyrics-word.is-current')?.textContent === 'se'", "Whole-word wrapping must preserve lyric spacing and syllable highlighting")
        print("PASS: Better Lyrics/lrcmux WebKit rendering, attribution, album cache refresh, words, seeking and whole-word wrapping")
        return
    }
    if plainUI {
        try await expect("getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none' && document.querySelector('.lyrics-scroll').hidden && !!document.querySelector('.lyrics-message button')",
                         "Unsynchronized external lyrics must leave the original plain lyrics visible")
        try await changeTrack("Metadata with timing")
        try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second real line'",
                         "JSON credit metadata in YRC must not hide the real timed LRC lyrics")
        try await changeTrack("Metadata only")
        try await expect("getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none' && document.querySelector('.lyrics-scroll').hidden && document.querySelectorAll('.lyrics-line').length === 0",
                         "Metadata-only responses must restore native lyrics without raw JSON")
        print("PASS: native plain lyrics, metadata rejection and valid LRC rendering through WebKit")
        return
    }
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
    try await expect("document.querySelector('.lyrics-source').textContent.includes('Line-by-line')", "Line-timed lyrics must identify their timing granularity")
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
    try await expect("!!document.querySelector('button[aria-label=\"Close lyric settings\"]')", "Timing settings need an explicit close button")
    _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
    _ = try await js("document.querySelector('button[aria-label=\"Close lyric settings\"]').click(); null")
    try await expect("document.querySelector('.lyrics-settings-panel').hidden && document.querySelector('.lyrics-settings-button').getAttribute('aria-expanded') === 'false' && document.activeElement === document.querySelector('.lyrics-settings-button') && document.querySelector('.lyrics-offset-input').value === '0.01'", "Closing timing settings must restore gear focus without changing the offset")
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
    try await expect("innerWidth === 400 && lineIsCentered() && document.querySelector('.lyrics-scroll').scrollWidth <= document.querySelector('.lyrics-scroll').clientWidth", "Wait for WebKit to resize before checking centering and wrapping")
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
                && rows.every((row, index) => row.offsetHeight === beforeWeightChange[index]);
        })()
        """, "All lyric lines stay bold, inactive lines dim, and wrapped lines keep their height")
    try await expect("lineIsCentered()", "Resize and line motion keep the active lyric centered")
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
    _ = try await js("document.querySelector('.lyrics-settings-button').click(); document.querySelector('.lyrics-seek')?.click(); null")
    try await expect("lastSeek === 1 && document.querySelector('.lyrics-line.is-current')?.textContent === 'First line' && document.querySelector('.lyrics-settings-panel').hidden", "Clicking a timed lyric must dismiss settings and seek in the same click")
    try await selectVersion("fixtureAA01")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0'", "An unconfigured version starts with zero offset")
    _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); document.querySelectorAll('.lyrics-seek')[1].click(); null")
    try await expect("lastSeek === 10.01 && document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Click-to-seek must include the configured timing offset")
    try await expectSavedOffset(10, for: "video:fixtureAA01")
    assert(MusicLyrics(defaults: defaults).trackOffsets["video:fixtureAA01|source:NetEase"] == 10, "A new native instance must read the saved offset")
    _ = try await js("document.documentElement.dataset.beforeOffsetReload = 'true'; null")
    web.loadHTMLString(pageHTML, baseURL: URL(string: "https://music.youtube.com/watch?v=fixtureAA01"))
    try await expect("!document.documentElement.dataset.beforeOffsetReload && !!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-offset-input').value === '0.01'", "A full document load without apply must restore the latest saved offset")
    lyrics.isEnabled = false
    try await update()
    lyrics.isEnabled = true
    try await update()
    try await expect("!!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-offset-input').value === '0.01'", "The song offset must survive a runtime restart through native preferences")
    try await selectVersion("fixtureBB02")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0'", "A different video with identical metadata must not inherit the previous offset")
    _ = try await js("document.querySelector('[data-offset=\"-10\"]').click(); document.querySelector('[data-offset=\"-10\"]').click(); null")
    try await selectVersion("fixtureAA01")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0.01'", "Returning to a version must restore its own saved offset")
    _ = try await js("document.querySelector('[data-reset]').click(); null")
    try await expectSavedOffset(nil, for: "video:fixtureAA01")
    _ = try await js("document.documentElement.dataset.beforeOffsetReload = 'true'; null")
    web.loadHTMLString(pageHTML, baseURL: URL(string: "https://music.youtube.com/watch?v=fixtureAA01"))
    try await expect("!document.documentElement.dataset.beforeOffsetReload && !!document.querySelector('.lyrics-line') && document.querySelector('.lyrics-offset-input').value === '0'", "A reset offset must not reappear after a full document load")
    try await selectVersion("fixtureBB02")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '-0.02'", "Reset must affect only the current version")
    _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); document.querySelector('[data-offset=\"10\"]').click(); null")
    try await expectSavedOffset(nil, for: "video:fixtureBB02")
    try await selectVersion("")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0'", "Missing video IDs fall back to track metadata")
    _ = try await js("document.querySelector('[data-offset=\"10\"]').click(); null")
    try await changeTrack("Cover version")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0'", "The metadata fallback must separate different versions")
    try await changeTrack("Fixture")
    try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-offset-input').value === '0.01'", "Metadata fallback offsets must also be restored")
    _ = try await js("document.querySelector('[data-reset]').click(); null")
    try await expectSavedOffset(nil, for: #"track:["fixture","artist",180]"#)
    assert(defaults.object(forKey: offsetsKey) == nil, "Zero offsets must leave no stored entries or empty container")
    _ = try await js("""
        for (const payload of [
            {trackKey:'video:invalid|source:NetEase', milliseconds:true},
            {trackKey:'video:invalid|source:NetEase', milliseconds:1.5},
            {trackKey:'video:invalid|source:NetEase', milliseconds:3600001},
            {trackKey:'video:invalid|source:Unknown', milliseconds:250},
            {trackKey:'video:invalid', milliseconds:250},
            {trackKey:'', milliseconds:250},
            {trackKey:'video:' + 'x'.repeat(2000) + '|source:NetEase', milliseconds:250}
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
    _ = try await js("document.querySelectorAll('.lyrics-seek')[1].click(); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && lineIsCentered()", "Clicking a line must resume centered scrolling immediately")
    _ = try await js("""
        window.beforeAnimatedSeek = document.querySelector('.lyrics-scroll').scrollTop;
        document.querySelectorAll('.lyrics-seek')[11].click();
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
        document.querySelectorAll('.lyrics-seek')[2].click();
        document.querySelectorAll('.lyrics-seek')[5].click();
        document.querySelectorAll('.lyrics-seek')[1].click(); null
        """)
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line' && lineIsCentered()", "Rapid seek clicks must retarget from the current position and settle on the latest line")
    _ = try await js("""
        window.highlightsDuringScroll = [20, 30, 40].map((time, index) => {
            fixtureTime = time;
            document.querySelector('video').dispatchEvent(new Event(index === 1 ? 'seeking' : 'timeupdate'));
            const current = document.querySelector('.lyrics-line.is-current');
            return current?.textContent === `Line ${time / 10}`;
        }); null
        """)
    try await expect("highlightsDuringScroll.every(Boolean)", "The active lyric marker must follow the audio clock while scrolling")
    _ = try await js("fixtureTime = 12; document.querySelector('video').dispatchEvent(new Event('seeked')); null")
    try await expect("lineIsCentered()", "Following still settles after immediate highlight changes")
    _ = try await js("""
        fixtureReduceMotion = true;
        document.querySelectorAll('.lyrics-seek')[11].click();
        window.reducedMotionCenteredImmediately = lineIsCentered(); null
        """)
    try await expect("reducedMotionCenteredImmediately", "Reduced Motion must center immediately without a lingering scroll animation")
    _ = try await js("fixtureReduceMotion = false; document.querySelectorAll('.lyrics-seek')[1].click(); null")
    try await expect("lineIsCentered()", "Restore animated following after Reduce Motion")
    let requestCount = LyricsTransport.lock.withLock { LyricsTransport.requests.count }
    _ = try await js("document.querySelectorAll('.lyrics-seek')[11].click(); document.querySelectorAll('[role=tab]')[1].setAttribute('aria-selected','false'); null")
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
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Finish a slow request", seconds: 6)
    try await changeTrack("Plain")
    try await expect("getComputedStyle(document.querySelector('#native-lyrics')).display !== 'none' && document.querySelector('.lyrics-scroll').hidden && !document.querySelector('.lyrics-line.is-current')", "Unsynchronized matches must use the original plain lyrics")
    try await expect("document.querySelectorAll('.lyrics-line').length === 0 && document.querySelector('#native-lyrics').textContent === 'Native lyrics'", "Untimed results must preserve native lyrics without fabricated seek positions")
    try await changeTrack("Better sync")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('LRCLIB') && document.querySelector('.lyrics-source').textContent.includes('Line-by-line') && document.querySelector('.lyrics-line.is-current')?.textContent === 'Fallback second'", "Prefer a synchronized fallback over an unsynchronized primary result")
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
        if title == "HTTP error" {
            try await expect("(() => { const text = document.querySelector('.lyrics-message > div').textContent; return text.includes('Couldn’t load synced lyrics.') && !text.includes('NetEase') && !text.includes('LRCLIB') && !text.includes('HTTP'); })()", "Hide provider diagnostics behind a simple message")
            try await expect("document.querySelector('.lyrics-info-button')?.getAttribute('aria-label') === 'Show error details' && document.querySelector('.lyrics-info-button').getAttribute('aria-expanded') === 'false'", "Offer accessible provider details on demand")
            _ = try await js("document.querySelector('.lyrics-info-button').click(); null")
            try await expect("document.querySelector('.lyrics-info-button').getAttribute('aria-expanded') === 'true' && !document.querySelector('.lyrics-error-text').hidden && document.querySelector('.lyrics-error-text').textContent.includes('NetEase') && document.querySelector('.lyrics-error-text').textContent.includes('HTTP 502')", "The info control reveals provider diagnostics inline")
            try await expect("getComputedStyle(document.querySelector('.lyrics-error-text')).position === 'static' && document.querySelector('.lyrics-error-text').getBoundingClientRect().bottom <= document.querySelector('#native-lyrics').getBoundingClientRect().top", "Expanded diagnostics must stay visible above native lyrics")
            _ = LyricsTransport.lock.withLock { LyricsTransport.recovered.insert(title) }
            _ = try await js("document.querySelector('.lyrics-message button:not(.lyrics-info-button)').click(); null")
            try await expect("!document.querySelector('.lyrics-scroll').hidden && document.querySelector('.lyrics-line.is-current')?.textContent === 'Second line'", "Try Again recovers from a provider error")
        } else if title == "Cooldown" {
            try await expect("document.querySelector('.lyrics-message button:not(.lyrics-info-button)').disabled", "Disable retry during server cooldown")
            try await expect("!document.querySelector('.lyrics-message button:not(.lyrics-info-button)').disabled", "Allow retry after cooldown")
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
    try await changeTrack("Cross source")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('LRCLIB') && document.querySelector('.lyrics-source').textContent.includes('Word-by-word')", "Prefer LRCLIB word timing over NetEase line timing")
    _ = try await js("fixtureTime = 1.5; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'First line' && document.querySelector('.lyrics-word.is-current')?.textContent.trim() === 'First'", "LRCLIB Lyricsfile words drive karaoke highlighting")
    try await changeTrack("AMLL words")
    try await expect("document.querySelector('.lyrics-source').textContent === 'Lyrics from AMLL · Word-by-word' && document.querySelectorAll('.lyrics-word').length === 2", "Render AMLL attribution without inferring an original provider from platform IDs")
    _ = try await js("fixtureTime = 1.5; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelector('.lyrics-line.is-current')?.textContent === 'Hello world' && document.querySelector('.lyrics-word.is-current')?.textContent.trim() === 'Hello'", "AMLL word timing must drive the existing karaoke renderer")
    _ = try await js("document.querySelectorAll('.lyrics-seek')[1].click(); null")
    try await expect("lastSeek === 10", "AMLL lyric lines must seek using their TTML timestamps")
    try await changeTrack("Word timing")
    try await expect("document.querySelector('.lyrics-source').textContent.includes('NetEase') && document.querySelector('.lyrics-source').textContent.includes('Word-by-word') && document.querySelectorAll('.lyrics-word').length === 2", "Find NetEase word timing in another matching release even when legacy search fails and LRCLIB offers line timing")
    _ = try await js("fixtureTime = 1.5; document.querySelector('video').dispatchEvent(new Event('timeupdate')); null")
    try await expect("document.querySelectorAll('.lyrics-word.is-current').length === 1 && document.querySelector('.lyrics-word.is-current').textContent.trim() === 'Hello'", "YRC word timing must highlight the active word")
    try await expect("(() => { const letters = [...document.querySelectorAll('.lyrics-word.is-current .lyrics-letter')]; return letters.length === 5 && letters.map(letter => letter.style.getPropertyValue('--word-progress')).join(',') === '100%,100%,50%,0%,0%'; })()", "YRC timing must fill letters from left to right")
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
    let probe = "webkit.messageHandlers.musicLyricsProvider.postMessage({trackKey:'video:blocked',source:'LRCLIB'}); webkit.messageHandlers.musicLyricsOffset.postMessage({trackKey:'video:blocked|source:NetEase',milliseconds:500}); webkit.messageHandlers.musicLyricsLookup.postMessage(\(payload)).then(() => document.body.dataset.reply='allowed', error => document.body.dataset.reply=String(error)); null;"
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
    assert(defaults.object(forKey: "MusicLyricsProvidersByTrack") == nil, "Untrusted frames must not save provider choices")
    assert(LyricsTransport.lock.withLock { LyricsTransport.requests.count } == calls, "Rejected frames must not contact providers")
    assert(MusicLyricsProvider.Track(["title": "", "artist": "Artist", "duration": 180.0]) == nil)
    assert(MusicLyricsProvider.Track(["title": "Fixture", "artist": "Artist", "duration": Double.infinity]) == nil)
    assert(MusicLyricsProvider.Track(["title": String(repeating: "a", count: 501), "artist": "Artist", "duration": 180.0]) == nil)
    print("PASS: \(label), native NetEase/LRCLIB/AMLL fallback, provider errors, timeout, cooldown, cache, matching, word sync, attribution, seeking, cleanup and cancellation")
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
