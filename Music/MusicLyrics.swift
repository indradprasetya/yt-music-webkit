import Foundation
import CoreFoundation
import WebKit
import AppKit

@MainActor
final class MusicLyrics: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    private let defaults: UserDefaults
    private let enabledKey = "MusicCustomLyricsEnabled"
    // KuGou cues tend to lag vocals; saved song offsets replace this starting adjustment.
    private static let kugouDefaultOffset = -200
    // Legacy offsets have no source identity; keep them untouched rather than guessing a provider.
    private let offsetsKey = "MusicLyricsOffsetsByTrackAndSource"
    private let providersKey = "MusicLyricsProvidersByTrack"
    private let languagesKey = "MusicLyricsLanguageByTrack"
    private let pronunciationKey = "MusicLyricsShowPronunciation"
    private var installedScript: WKUserScript?
    private let provider: MusicLyricsProvider
    private let translation: MusicLyricsTranslation
    private var lookupTask: Task<Void, Never>?

    init(provider: MusicLyricsProvider? = nil, defaults: UserDefaults = .standard) {
        self.provider = provider ?? MusicLyricsProvider()
        self.defaults = defaults
        translation = MusicLyricsTranslation(defaults: defaults)
        super.init()
    }

    func connect(to controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: "musicLyricsLookup")
        controller.add(self, contentWorld: .defaultClient, name: "musicLyricsOffset")
        controller.add(self, contentWorld: .defaultClient, name: "musicLyricsProvider")
        controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: "musicLyricsLanguage")
    }

    func attach(to view: NSView) { translation.attach(to: view) }

    func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        translation.cancel()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard isYouTubeMusic(message.frameInfo) else {
            replyHandler(nil, "Lyrics are available only on YouTube Music.")
            return
        }
        if message.name == "musicLyricsLanguage" {
            guard isEnabled, let body = message.body as? [String: Any] else {
                replyHandler(nil, "Synced lyrics are disabled.")
                return
            }
            if body["action"] as? String == "pronunciationPreference" {
                guard let enabled = body["enabled"] as? Bool else {
                    replyHandler(nil, "Invalid pronunciation preference.")
                    return
                }
                defaults.set(enabled, forKey: pronunciationKey)
                apply(to: userContentController)
                replyHandler(["status": "saved"], nil)
                return
            }
            if body["action"] as? String == "trackPreferences" {
                guard let key = body["trackKey"] as? String, validTrackKey(key), !key.hasPrefix("mode:"),
                      let translate = body["translate"] as? Bool else {
                    replyHandler(nil, "Invalid song language preferences.")
                    return
                }
                var saved = trackLanguages
                if translate { saved[key] = ["translate": true] }
                else { saved.removeValue(forKey: key) }
                if saved.isEmpty { defaults.removeObject(forKey: languagesKey) }
                else { defaults.set(saved, forKey: languagesKey) }
                apply(to: userContentController)
                replyHandler(["status": "saved"], nil)
                return
            }
            let token = body["token"] as? Int
            translation.handle(body, onStatus: { [weak webView = message.webView] phase in
                guard let token, token >= 0 else { return }
                webView?.callAsyncJavaScript("window.musicCustomLyrics?.translationStatus(token, phase); return null;",
                    arguments: ["token": token, "phase": phase], in: nil, in: .defaultClient, completionHandler: nil)
            }) { [weak self] value, error in
                if body["action"] as? String == "preferences", error == nil { self?.apply(to: userContentController) }
                replyHandler(value, error)
            }
            return
        }
        if (message.body as? [String: Any])?["action"] as? String == "cancel" {
            cancelLookup()
            replyHandler(["status": "cancelled"], nil)
            return
        }
        guard isEnabled, let track = MusicLyricsProvider.Track(message.body) else {
            replyHandler(nil, "Synced lyrics are disabled or track information is invalid.")
            return
        }
        cancelLookup()
        lookupTask = Task {
            do {
                let result = try await provider.lookup(track)
                try Task.checkCancellation()
                replyHandler(result.dictionary, nil)
            } catch {
                replyHandler(["status": "cancelled"], nil)
            }
        }
    }

    private func isYouTubeMusic(_ frame: WKFrameInfo) -> Bool {
        let origin = frame.securityOrigin
        return frame.isMainFrame && origin.protocol == "https" && origin.host == "music.youtube.com"
            && (origin.port == 0 || origin.port == 443)
    }

    private func validSource(_ source: String) -> Bool {
        ["NetEase", "LRCLIB", "AMLL", "Better Lyrics", "lrcmux", "lrcmux (Deezer)",
               "lrcmux (KuGou)", "lrcmux (YouTube Music)", "lrcmux (Genius)", "lrcmux (Musixmatch)"]
            .contains(source)
    }

    private func validOffsetKey(_ key: String) -> Bool {
        guard key.utf8.count <= 2200, let separator = key.range(of: "|source:", options: .backwards),
              validSource(String(key[separator.upperBound...])) else { return false }
        return validTrackKey(String(key[..<separator.lowerBound]))
    }

    private func validTrackKey(_ key: String) -> Bool {
        guard key.utf8.count <= 2100 else { return false }
        var identity = key
        if identity.hasPrefix("mode:") {
            guard let separator = identity.firstIndex(of: "|"),
                  ["mode:song", "mode:video"].contains(String(identity[..<separator])) else { return false }
            identity = String(identity[identity.index(after: separator)...])
        }
        if identity.hasPrefix("video:") {
            return identity.range(of: #"^video:[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
        }
        return identity.hasPrefix("track:") && identity.count > 6 && identity.utf8.count <= 2048
    }

    private func validOffset(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let milliseconds = number as? Int, (-3_600_000...3_600_000).contains(milliseconds) else { return nil }
        return milliseconds
    }

    private func defaultOffset(for key: String) -> Int {
        key.hasSuffix("|source:lrcmux (KuGou)") ? Self.kugouDefaultOffset : 0
    }

    var trackOffsets: [String: Int] {
        (defaults.dictionary(forKey: offsetsKey) ?? [:]).reduce(into: [:]) { result, entry in
            guard validOffsetKey(entry.key), let value = validOffset(entry.value), value != defaultOffset(for: entry.key) else { return }
            result[entry.key] = value
        }
    }

    private var trackProviders: [String: String] {
        (defaults.dictionary(forKey: providersKey) ?? [:]).reduce(into: [:]) { result, entry in
            guard validTrackKey(entry.key), let source = entry.value as? String, validSource(source) else { return }
            result[entry.key] = source
        }
    }

    private var trackLanguages: [String: [String: Bool]] {
        (defaults.dictionary(forKey: languagesKey) ?? [:]).reduce(into: [:]) { result, entry in
            guard validTrackKey(entry.key), !entry.key.hasPrefix("mode:"),
                  let value = entry.value as? [String: Bool],
                  value["translate"] == true else { return }
            result[entry.key] = ["translate": true]
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "musicLyricsProvider" {
            guard isEnabled, isYouTubeMusic(message.frameInfo), let body = message.body as? [String: Any],
                  let key = body["trackKey"] as? String, validTrackKey(key),
                  let source = body["source"] as? String, source.isEmpty || validSource(source) else { return }
            var providers = trackProviders
            if source.isEmpty { providers.removeValue(forKey: key) } else { providers[key] = source }
            if providers.isEmpty { defaults.removeObject(forKey: providersKey) }
            else { defaults.set(providers, forKey: providersKey) }
            apply(to: controller)
            return
        }
        guard message.name == "musicLyricsOffset", isYouTubeMusic(message.frameInfo),
              let body = message.body as? [String: Any], let key = body["trackKey"] as? String,
              validOffsetKey(key), let value = validOffset(body["milliseconds"]) else { return }
        var offsets = trackOffsets
        if value == defaultOffset(for: key) { offsets.removeValue(forKey: key) } else { offsets[key] = value }
        if offsets.isEmpty { defaults.removeObject(forKey: offsetsKey) }
        else { defaults.set(offsets, forKey: offsetsKey) }
        // Future documents must receive the latest offsets, including deletions.
        apply(to: controller)
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: enabledKey)
            if !newValue { cancelLookup() }
        }
    }

    func apply(to controller: WKUserContentController) {
        let retainedScripts = controller.userScripts.filter { $0 !== installedScript }
        controller.removeAllUserScripts()
        retainedScripts.forEach(controller.addUserScript)
        installedScript = nil
        guard isEnabled else { return }
        let offsets = (try? JSONEncoder().encode(trackOffsets)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let providers = (try? JSONEncoder().encode(trackProviders)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var preferences = translation.preferences
        preferences["pronunciation"] = defaults.object(forKey: pronunciationKey) as? Bool ?? true
        let languages = (try? JSONSerialization.data(withJSONObject: preferences)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let trackLanguageJSON = (try? JSONEncoder().encode(trackLanguages)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let script = WKUserScript(source: Self.source(offsets: offsets, providers: providers, languages: languages, trackLanguages: trackLanguageJSON),
                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        controller.addUserScript(script)
        installedScript = script
    }

    func update(in webView: WKWebView, completion: @escaping (Error?) -> Void) {
        apply(to: webView.configuration.userContentController)
        guard webView.url?.scheme == "https", webView.url?.host == "music.youtube.com" else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(installedScript?.source ?? "window.musicCustomLyrics?.stop();",
                                  in: nil, in: .defaultClient) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    private static func source(offsets: String, providers: String, languages: String, trackLanguages: String) -> String {
        """
        (() => {
            if (location.origin !== 'https://music.youtube.com') return;
            window.musicCustomLyrics?.stop();

            const lifetime = new AbortController();
            const style = document.createElement('style');
            style.textContent = `
                ytmusic-player-page #tab-renderer { position: relative !important; }
                #tab-renderer:has(> #music-custom-lyrics.is-notice:not([hidden])) {
                    display: flex !important; flex-direction: column !important;
                }
                #tab-renderer:has(> #music-custom-lyrics.is-notice:not([hidden])) > :not(#music-custom-lyrics) {
                    min-height: 0;
                }
                #tab-renderer.music-custom-lyrics-active > :not(#music-custom-lyrics) { display: none !important; }
                #tab-renderer.music-custom-lyrics-active { overflow: hidden !important; }
                #music-custom-lyrics {
                    position: absolute; inset: 0; z-index: 5; box-sizing: border-box;
                    display: flex; flex-direction: column; min-width: 0; min-height: 0;
                    padding: 0; overflow: hidden;
                    color: #f5f5f5; background: transparent;
                    font-family: inherit; isolation: isolate;
                }
                #music-custom-lyrics[hidden], #music-custom-lyrics [hidden] { display: none !important; }
                #music-custom-lyrics .lyrics-toolbar {
                    display: flex; justify-content: flex-end; align-items: center; gap: 8px;
                    min-height: 34px; position: absolute; top: 8px; left: 0; right: 14px; z-index: 2;
                    pointer-events: none;
                }
                #music-custom-lyrics .lyrics-toolbar-button {
                    display: grid; place-items: center; flex: 0 0 34px; width: 34px; height: 34px;
                    padding: 0; border: 0; border-radius: 50%; color: rgba(255,255,255,.6);
                    background: transparent; outline: none; cursor: pointer; pointer-events: auto;
                }
                #music-custom-lyrics .lyrics-toolbar-button:hover,
                #music-custom-lyrics .lyrics-toolbar-button:focus-visible { color: #fff; background: rgba(255,255,255,.12); }
                #music-custom-lyrics .lyrics-toolbar-button[aria-pressed="true"] { color: #fff; background: transparent; }
                #music-custom-lyrics button:focus-visible { outline: 2px solid rgba(255,255,255,.78); outline-offset: 2px; }
                #music-custom-lyrics .lyrics-toolbar-button svg { width: 19px; height: 19px; fill: currentColor; }
                #music-custom-lyrics .lyrics-pronunciation-button svg { fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
                #music-custom-lyrics .lyrics-pronunciation-button[aria-pressed="true"] svg { stroke-width: 2.4; }
                #music-custom-lyrics .lyrics-translate-button[aria-pressed="true"] svg { stroke: currentColor; stroke-width: .5; stroke-linejoin: round; }
                #music-custom-lyrics .lyrics-translation-spinner { display: none; }
                #music-custom-lyrics .lyrics-translate-button[aria-pressed="true"][aria-busy="true"] .lyrics-translation-spinner { display: block; }
                #music-custom-lyrics .lyrics-translate-button[aria-pressed="true"][aria-busy="true"] svg { display: none; }
                #music-custom-lyrics .lyrics-settings-panel {
                    position: absolute; top: 42px; right: 0; z-index: 3;
                    width: 248px; max-width: 100%; max-height: calc(100vh - 180px); overflow-y: auto; box-sizing: border-box;
                    padding: 12px; border: 0; border-radius: 8px; pointer-events: auto;
                    background: var(--ytmusic-menu-background, #282828); color: #f5f5f5;
                    box-shadow: 0 8px 24px rgba(0,0,0,.32);
                }
                #music-custom-lyrics .lyrics-settings-panel h2 {
                    margin: 0 36px 8px 0; font-size: 14px; font-weight: 500; line-height: 20px;
                }
                #music-custom-lyrics .lyrics-provider-section,
                #music-custom-lyrics .lyrics-translation-section {
                    margin-top: 12px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,.12);
                }
                #music-custom-lyrics .lyrics-provider-label,
                #music-custom-lyrics .lyrics-language-target {
                    display: block; margin-bottom: 4px; color: rgba(255,255,255,.7); font-size: 12px; line-height: 16px;
                }
                #music-custom-lyrics .lyrics-provider-control,
                #music-custom-lyrics .lyrics-language-control { position: relative; }
                #music-custom-lyrics .lyrics-provider-select,
                #music-custom-lyrics .lyrics-language-select {
                    display: block; width: 100%; min-height: 36px; box-sizing: border-box;
                    padding: 6px 28px 6px 0; border: 0; border-radius: 4px;
                    color: #f5f5f5; background: transparent; color-scheme: dark; font: inherit; font-size: 14px;
                    -webkit-appearance: none; appearance: none; cursor: pointer; text-overflow: ellipsis;
                }
                #music-custom-lyrics .lyrics-provider-select:hover,
                #music-custom-lyrics .lyrics-language-select:hover { background: rgba(255,255,255,.08); }
                #music-custom-lyrics .lyrics-provider-select:focus-visible,
                #music-custom-lyrics .lyrics-language-select:focus-visible {
                    outline: 2px solid rgba(255,255,255,.78); outline-offset: 2px;
                }
                #music-custom-lyrics .lyrics-provider-chevron,
                #music-custom-lyrics .lyrics-language-chevron {
                    position: absolute; right: 4px; top: 50%; transform: translateY(-50%);
                    width: 18px; height: 18px; color: rgba(255,255,255,.7); pointer-events: none;
                }
                #music-custom-lyrics .lyrics-provider-note,
                #music-custom-lyrics .lyrics-language-note {
                    margin: 4px 0 0; color: rgba(255,255,255,.65); font-size: 11px; line-height: 16px;
                }
                #music-custom-lyrics .lyrics-language-help {
                    margin: 8px 0 0;
                    color: rgba(255,255,255,.7); font-size: 11px; line-height: 16px;
                }
                #music-custom-lyrics .lyrics-language-system-settings {
                    display: inline-flex; align-items: center; gap: 5px; min-height: 32px; max-width: 100%;
                    padding: 4px 0; border: 0; border-radius: 3px; background: transparent; color: #f5f5f5;
                    font-family: inherit; font-size: 12px; font-weight: 500; text-align: left; cursor: pointer;
                }
                #music-custom-lyrics .lyrics-language-system-settings:hover { text-decoration: underline; text-underline-offset: 3px; }
                #music-custom-lyrics .lyrics-language-system-settings svg { flex: 0 0 auto; width: 14px; height: 14px; }
                #music-custom-lyrics .lyrics-offset-controls {
                    display: grid; grid-template-columns: 36px minmax(0, 1fr) 36px;
                    align-items: center; gap: 8px; padding: 4px 0;
                }
                #music-custom-lyrics .lyrics-offset-controls button,
                #music-custom-lyrics .lyrics-close-button {
                    display: grid; place-items: center; width: 36px; height: 36px;
                    padding: 0; border: 0; border-radius: 50%; color: #fff;
                    background: transparent; cursor: pointer;
                }
                #music-custom-lyrics .lyrics-close-button { position: absolute; top: 4px; right: 4px; }
                #music-custom-lyrics .lyrics-offset-controls button svg,
                #music-custom-lyrics .lyrics-close-button svg { width: 20px; height: 20px; }
                #music-custom-lyrics .lyrics-offset-value {
                    display: flex; align-items: center; justify-content: center; gap: 4px;
                    font-size: 16px; font-weight: 500;
                    line-height: 24px; font-variant-numeric: tabular-nums;
                }
                #music-custom-lyrics .lyrics-offset-input {
                    box-sizing: border-box; width: 9ch; min-width: 0; min-height: 36px; padding: 4px 2px;
                    border: 0; border-radius: 4px; color: inherit; background: transparent;
                    font: inherit; text-align: center; appearance: textfield;
                }
                #music-custom-lyrics .lyrics-offset-input::-webkit-inner-spin-button,
                #music-custom-lyrics .lyrics-offset-input::-webkit-outer-spin-button { appearance: none; margin: 0; }
                #music-custom-lyrics .lyrics-offset-input:hover,
                #music-custom-lyrics .lyrics-offset-input:focus { background: rgba(255,255,255,.08); }
                #music-custom-lyrics .lyrics-offset-input:focus-visible {
                    outline: 2px solid rgba(255,255,255,.78); outline-offset: 2px;
                }
                #music-custom-lyrics .lyrics-offset-footer {
                    display: flex; align-items: center; justify-content: space-between;
                    gap: 8px; margin-top: 8px;
                }
                #music-custom-lyrics .lyrics-reset-button {
                    flex-shrink: 0; min-height: 28px;
                    padding: 0 8px; border: 0; border-radius: 14px;
                    color: rgba(255,255,255,.7); background: transparent; cursor: pointer;
                    font-family: inherit; font-size: 12px; font-weight: 500; line-height: 20px;
                }
                #music-custom-lyrics .lyrics-offset-controls button:hover,
                #music-custom-lyrics .lyrics-close-button:hover,
                #music-custom-lyrics .lyrics-reset-button:hover { background: rgba(255,255,255,.1); }
                #music-custom-lyrics .lyrics-offset-controls button:active,
                #music-custom-lyrics .lyrics-close-button:active,
                #music-custom-lyrics .lyrics-reset-button:active { background: rgba(255,255,255,.16); }
                #music-custom-lyrics .lyrics-offset-note {
                    margin: 0; color: rgba(255,255,255,.65); font-size: 11px; line-height: 16px;
                }
                #music-custom-lyrics .lyrics-scroll {
                    flex: 1; min-height: 0; overflow-x: hidden; overflow-y: auto;
                    overscroll-behavior: contain; scrollbar-width: auto; scroll-behavior: auto; overflow-anchor: none;
                    mask-image: linear-gradient(to bottom, transparent, #000 12%, #000 86%, transparent), linear-gradient(#000, #000);
                    mask-size: calc(100% - 14px) 100%, 14px 100%;
                    mask-position: left top, right top; mask-repeat: no-repeat;
                }
                #music-custom-lyrics .lyrics-scroll::before,
                #music-custom-lyrics .lyrics-scroll::after {
                    position: sticky; z-index: 1; display: block; height: 64px; margin-inline-end: 14px;
                    content: ''; pointer-events: none; -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px);
                }
                #music-custom-lyrics .lyrics-scroll::before {
                    top: 0; margin-bottom: -64px; background: linear-gradient(to bottom, rgba(0,0,0,.28), transparent);
                    -webkit-mask-image: linear-gradient(to bottom, #000, transparent); mask-image: linear-gradient(to bottom, #000, transparent);
                }
                #music-custom-lyrics .lyrics-scroll::after {
                    bottom: 0; margin-top: -64px; background: linear-gradient(to top, rgba(0,0,0,.28), transparent);
                    -webkit-mask-image: linear-gradient(to top, #000, transparent); mask-image: linear-gradient(to top, #000, transparent);
                }
                #music-custom-lyrics .lyrics-scroll:has(.lyrics-lines.is-plain) { mask-image: none; }
                #music-custom-lyrics .lyrics-scroll:has(.lyrics-lines.is-plain)::before,
                #music-custom-lyrics .lyrics-scroll:has(.lyrics-lines.is-plain)::after { display: none; }
                #music-custom-lyrics .lyrics-scroll::-webkit-scrollbar { width: 14px; background: transparent; }
                #music-custom-lyrics .lyrics-scroll::-webkit-scrollbar-track { background: transparent; }
                #music-custom-lyrics .lyrics-scroll::-webkit-scrollbar-thumb {
                    min-height: 32px; border: 3px solid transparent; border-radius: 10px;
                    background: rgba(255,255,255,.45); background-clip: padding-box;
                }
                #music-custom-lyrics .lyrics-scroll::-webkit-scrollbar-thumb:hover { background-color: rgba(255,255,255,.65); }
                #music-custom-lyrics .lyrics-scroll::-webkit-scrollbar-thumb:active { background-color: rgba(255,255,255,.8); }
                #music-custom-lyrics .lyrics-lines {
                    display: flex; flex-direction: column; padding: 16px 0 24px;
                }
                #music-custom-lyrics .lyrics-line {
                    margin: 0; color: rgba(255,255,255,.24); font-size: clamp(20px, 1.7vw, 26px);
                    font-weight: 700; line-height: 1.28; letter-spacing: -.018em;
                    transition: color .42s ease, opacity .45s cubic-bezier(.33,0,.67,1);
                }
                /* WebKit grid rows can retain stale lyric heights after resizing. */
                #music-custom-lyrics .lyrics-line:has(> .lyrics-align) {
                    position: relative; padding-inline-end: 48px;
                }
                #music-custom-lyrics .lyrics-line + .lyrics-line { margin-top: 24px; }
                #music-custom-lyrics .lyrics-lines.is-following .lyrics-line.is-past {
                    opacity: 0; pointer-events: none;
                }
                #music-custom-lyrics .lyrics-lines.is-following .lyrics-line.is-fading { color: #fff; }
                #music-custom-lyrics .lyrics-lines:not(.is-following) .lyrics-line.is-past {
                    transition: opacity .45s cubic-bezier(.33,0,.67,1);
                }
                #music-custom-lyrics .lyrics-pause { display: none; }
                #music-custom-lyrics .lyrics-pause.is-visible {
                    display: flex; flex-shrink: 0; align-items: center; gap: 10px;
                    height: 24px; margin: 24px 0 0; padding-inline-start: 2px;
                }
                #music-custom-lyrics .lyrics-pause span {
                    width: 10px; height: 10px; border-radius: 50%; background: #f5f5f5;
                }
                #music-custom-lyrics .lyrics-pause + .lyrics-line { margin-top: 24px; }
                #music-custom-lyrics .lyrics-pronunciation,
                #music-custom-lyrics .lyrics-translation {
                    display: block; margin-top: 5px; font-size: .64em; font-weight: 500;
                    line-height: 1.45; letter-spacing: 0; overflow-wrap: anywhere; text-shadow: none;
                    color: inherit;
                }
                #music-custom-lyrics .lyrics-pronunciation { font-size: .73em; font-weight: 600; }
                #music-custom-lyrics .is-current .lyrics-translation { color: rgba(255,255,255,.8); }
                #music-custom-lyrics .lyrics-line:has(.lyrics-pronunciation:not([hidden]), .lyrics-translation:not([hidden])) > .lyrics-align { top: 18px; }
                #music-custom-lyrics .lyrics-line.is-credit + .lyrics-line.is-credit { margin-top: 0; }
                #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-seek {
                    transform: translateY(3px) scale(.94); transform-origin: left center;
                    transition: transform .42s cubic-bezier(.16,1,.3,1);
                }
                #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-line.is-current {
                    color: #fff;
                    text-shadow: 0 0 8px rgba(255,255,255,.12);
                }
                #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-line.is-current .lyrics-seek {
                    transform: translateY(-3px) scale(1);
                }
                #music-custom-lyrics .lyrics-lines.is-following .lyrics-line.is-fading .lyrics-seek {
                    transform: translateY(-3px) scale(1);
                }
                #music-custom-lyrics .lyrics-line .lyrics-word {
                    display: inline; white-space: pre;
                }
                #music-custom-lyrics .lyrics-line.is-current .lyrics-word {
                    color: rgba(255,255,255,.24);
                }
                #music-custom-lyrics .lyrics-letter { display: inline; }
                #music-custom-lyrics .lyrics-line.is-current .lyrics-word .lyrics-letter,
                #music-custom-lyrics .lyrics-lines.is-following .lyrics-line.is-fading .lyrics-word .lyrics-letter {
                    color: transparent; -webkit-text-fill-color: transparent;
                    background-image: linear-gradient(to right, #fff 0, #fff var(--word-progress, 0%),
                        rgba(255,255,255,.24) var(--word-progress, 0%), rgba(255,255,255,.24) 100%);
                    background-size: 100% 100%; background-repeat: no-repeat;
                    background-clip: text; -webkit-background-clip: text;
                    text-shadow: none;
                }
                #music-custom-lyrics .lyrics-lines .lyrics-line.is-credit {
                    font-size: 14px; font-weight: 400; line-height: 1.5; letter-spacing: normal;
                    color: rgba(245,245,245,.65); transform: none;
                }
                #music-custom-lyrics .lyrics-lines.is-plain .lyrics-line { color: #f5f5f5; }
                #music-custom-lyrics .lyrics-seek {
                    display: block; width: 100%; min-width: 0; min-height: 36px; padding: 2px 0; overflow-wrap: anywhere;
                    border: 0; color: inherit; background: transparent; text-align: left;
                    font: inherit; line-height: inherit; letter-spacing: inherit;
                    cursor: pointer; -webkit-user-select: none;
                }
                #music-custom-lyrics .lyrics-seek:hover { background: rgba(255,255,255,.04); }
                #music-custom-lyrics .lyrics-seek:focus-visible { outline-offset: -2px; border-radius: 4px; }
                #music-custom-lyrics .lyrics-line:not(.is-current) .lyrics-seek:focus-visible { color: rgba(245,245,245,.8); }
                #music-custom-lyrics .lyrics-align {
                    position: absolute; inset-inline-end: 0; top: 50%; transform: translateY(-50%);
                    display: grid; place-items: center; width: 36px; height: 36px;
                    padding: 0; border: 0; border-radius: 50%; color: rgba(255,255,255,.42);
                    background: transparent; cursor: pointer; opacity: 0; pointer-events: none;
                    transition: opacity .2s ease;
                }
                #music-custom-lyrics .lyrics-line.is-sync-hovered > .lyrics-align,
                #music-custom-lyrics .lyrics-line:has(:focus-visible) > .lyrics-align { opacity: 1; pointer-events: auto; }
                #music-custom-lyrics .lyrics-align:hover,
                #music-custom-lyrics .lyrics-align:focus-visible { color: #fff; background: rgba(255,255,255,.12); }
                #music-custom-lyrics .lyrics-align:focus-visible { outline-offset: -2px; }
                #music-custom-lyrics .lyrics-align:active { background: rgba(255,255,255,.2); }
                #music-custom-lyrics .lyrics-align svg { width: 20px; height: 20px; }
                #music-custom-lyrics .lyrics-feedback {
                    position: absolute; width: 1px; height: 1px; padding: 0; overflow: hidden;
                    clip-path: inset(50%); white-space: nowrap;
                }
                @media (hover: none) {
                    #music-custom-lyrics .lyrics-align { opacity: 1; pointer-events: auto; }
                }
                #music-custom-lyrics .lyrics-message {
                    display: grid; flex: 1; place-content: center; gap: 8px;
                    color: rgba(255,255,255,.7); text-align: center; font-size: 15px; line-height: 1.45;
                }
                #music-custom-lyrics .lyrics-message button {
                    justify-self: center; margin-top: 6px; padding: 7px 12px;
                    border: 0; border-radius: 7px; color: #fff; background: rgba(255,255,255,.12);
                    font-family: inherit; font-size: 13px; font-weight: 500; line-height: 1.2; cursor: pointer;
                }
                #music-custom-lyrics.is-notice {
                    position: relative; inset: auto; flex: 0 0 auto;
                    margin-bottom: 0; padding: 8px 12px;
                    border-bottom: 1px solid rgba(255,255,255,.08);
                    background: transparent;
                }
                #music-custom-lyrics.is-notice .lyrics-toolbar,
                #music-custom-lyrics.is-notice .lyrics-scroll,
                #music-custom-lyrics.is-notice .lyrics-source { display: none; }
                #music-custom-lyrics.is-notice .lyrics-message {
                    display: grid; flex: 0 0 auto; grid-template-columns: minmax(0, 1fr) auto;
                    align-items: center; gap: 8px 12px; text-align: left;
                    font-size: 13px; line-height: 20px; color: rgba(255,255,255,.7);
                }
                #music-custom-lyrics.is-notice .lyrics-message-text {
                    display: flex; align-items: center; gap: 10px; min-width: 0; overflow-wrap: anywhere;
                }
                #music-custom-lyrics .lyrics-spinner,
                #music-custom-lyrics .lyrics-translation-spinner {
                    flex: 0 0 auto; width: 16px; height: 16px; box-sizing: border-box;
                    border: 2px solid rgba(255,255,255,.2); border-top-color: rgba(255,255,255,.85);
                    border-radius: 50%; animation: music-lyrics-spin .8s linear infinite;
                }
                @keyframes music-lyrics-spin { to { transform: rotate(360deg); } }
                #music-custom-lyrics.is-notice .lyrics-message-actions {
                    display: flex; align-items: center; gap: 4px;
                }
                #music-custom-lyrics.is-notice .lyrics-message-actions > button {
                    display: inline-flex; flex: 0 0 auto; align-items: center; justify-content: center;
                    height: 36px; min-height: 36px; margin: 0; padding: 0 12px;
                    border: 0; border-radius: 18px; color: #f5f5f5;
                    background: rgba(255,255,255,.12); font-family: inherit;
                    font-size: 13px; font-weight: 500; line-height: 20px;
                    -webkit-appearance: none; appearance: none; cursor: pointer;
                }
                #music-custom-lyrics.is-notice .lyrics-message-actions > button:hover { background: rgba(255,255,255,.2); }
                #music-custom-lyrics.is-notice .lyrics-message-actions > button:disabled {
                    opacity: .45; cursor: default;
                }
                #music-custom-lyrics.is-notice .lyrics-message-actions > .lyrics-info-button {
                    width: 34px; min-width: 34px; height: 34px; min-height: 34px;
                    padding: 0; border-radius: 50%;
                    color: rgba(255,255,255,.78); background: transparent;
                }
                #music-custom-lyrics.is-notice .lyrics-info-button:hover,
                #music-custom-lyrics.is-notice .lyrics-info-button[aria-expanded="true"] {
                    color: #fff; background: rgba(255,255,255,.12);
                }
                #music-custom-lyrics.is-notice .lyrics-info-button svg {
                    width: 18px; height: 18px; fill: none; stroke: currentColor;
                    stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round;
                }
                #music-custom-lyrics.is-notice .lyrics-info-button:focus-visible {
                    outline: 2px solid rgba(255,255,255,.78); outline-offset: 2px;
                }
                #music-custom-lyrics.is-notice .lyrics-message .lyrics-error-text {
                    position: static; grid-column: 1 / -1; width: auto; max-width: 100%; box-sizing: border-box;
                    margin: 0; padding: 9px 12px; border-radius: 6px;
                    color: rgba(255,255,255,.78); background: rgba(255,255,255,.08);
                    text-align: left;
                    font-size: 12px; line-height: 1.4; overflow-wrap: anywhere;
                }
                #music-custom-lyrics .lyrics-source {
                    min-height: 19px; color: rgba(255,255,255,.65); font-size: 11px;
                    padding: 8px 0; text-align: center; letter-spacing: .01em;
                }
                @media (prefers-reduced-motion: reduce) {
                    #music-custom-lyrics .lyrics-spinner,
                    #music-custom-lyrics .lyrics-translation-spinner { animation: none; }
                    #music-custom-lyrics .lyrics-line,
                    #music-custom-lyrics .lyrics-seek,
                    #music-custom-lyrics .lyrics-align,
                    #music-custom-lyrics .lyrics-pause,
                    #music-custom-lyrics .lyrics-pause + .lyrics-line { transition: none !important; }
                    #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-seek { transform: none; }
                    #music-custom-lyrics .lyrics-scroll { scroll-behavior: auto !important; }
                    #music-custom-lyrics .lyrics-line .lyrics-word { transition: none !important; text-shadow: none !important; filter: none !important; }
                }
            `;
            document.documentElement.append(style);

            const cache = new Map();
            const creditPattern = /^(?:作词|作詞|作曲|编曲|編曲|制作人|製作人|监制|監製|词|詞|曲|작사|작곡|편곡|composer|lyricist|arranger|producer|lyrics(?:\\s+by)?|music(?:\\s+by)?|words(?:\\s+by)?|written\\s+by|composed\\s+by|arranged\\s+by|produced\\s+by|penulis|pencipta)\\s*[:：]/iu;
            let overlay = null;
            let panel = null;
            let trackKey = '';
            let loadingKey = '';
            let completedKey = '';
            let activeLines = [];
            let activeIndex = -1;
            const savedOffsets = \(offsets);
            const savedProviders = \(providers);
            const languagePreferences = \(languages);
            const savedLanguagePreferences = \(trackLanguages);
            // Temporarily hide translation while synced lyrics is in beta.
            const translationEnabled = false;
            const currentLanguagePreferences = {translate: false, pronunciation: languagePreferences.pronunciation !== false};
            const translationCache = new Map();
            const pronunciationCache = new Map();
            let translationGeneration = 0;
            let pronunciationGeneration = 0;
            let languageTrackKey = '';
            let preferenceSave = Promise.resolve();
            let languagesReady = null;
            let currentResult = null;
            let offsetTrackKey = '';
            let defaultOffset = 0;
            let offset = 0;
            let retryAfter = 0;
            let userScrollUntil = 0;
            let syncResumeTimer = 0;
            let syncScrollPaused = false;
            let syncPointerX = null;
            let syncPointerY = null;
            let frame = 0;
            let scrollFrame = 0;
            let scrollTarget = 0;
            let contentAnimation = null;
            const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
            const graphemeSegmenter = new Intl.Segmenter(undefined, {granularity: 'grapheme'});

            function updateSyncControl() {
                const scroll = overlay?.querySelector('.lyrics-scroll');
                const previous = scroll?.querySelector('.lyrics-line.is-sync-hovered');
                let row = syncPointerX == null || syncPointerY == null ? null
                    : document.elementFromPoint(syncPointerX, syncPointerY)?.closest('.lyrics-line');
                const button = scroll?.contains(row) ? row.querySelector('.lyrics-align') : null;
                if (button) {
                    const bounds = button.getBoundingClientRect();
                    const viewport = scroll.getBoundingClientRect();
                    const fade = scroll.clientHeight * .12;
                    if (bounds.top < viewport.top + fade || bounds.bottom > viewport.top + scroll.clientHeight - fade) row = null;
                } else row = null;
                if (previous !== row) {
                    previous?.classList.remove('is-sync-hovered');
                    row?.classList.add('is-sync-hovered');
                }
            }

            function hideSyncControls() {
                syncPointerX = syncPointerY = null;
                updateSyncControl();
                clearTimeout(syncResumeTimer);
                syncResumeTimer = setTimeout(() => {
                    syncScrollPaused = false;
                    updateActiveLine(true);
                }, reducedMotion.matches ? 0 : 200);
            }

            function showSyncControls(event) {
                if (!activeLines.length || event.pointerType === 'touch') return;
                if (event.type === 'pointermove' && event.clientX === syncPointerX && event.clientY === syncPointerY) return;
                syncPointerX = event.clientX;
                syncPointerY = event.clientY;
                clearTimeout(syncResumeTimer);
                overlay?.querySelector('.lyrics-lines')?.classList.remove('is-following');
                syncResumeTimer = setTimeout(() => {
                    syncScrollPaused = false;
                    updateActiveLine(true);
                }, 3000);
                cancelScroll();
                syncScrollPaused = true;
                updateSyncControl();
            }

            function mediaElement() {
                const media = [...document.querySelectorAll('video, audio')];
                return media.find(item => !item.paused && !item.ended && Number.isFinite(item.duration))
                    || media.find(item => Number.isFinite(item.duration));
            }

            function playbackMode() {
                const page = document.querySelector('ytmusic-player-page');
                // shortcut: these YouTube player attributes are undocumented; revisit if its mode controls change.
                if (page?.hasAttribute('video-mode')) return 'video';
                const preference = page?.querySelector('ytmusic-av-toggle')?.getAttribute('playback-mode');
                if (preference === 'ATV_PREFERRED') return 'song';
                if (preference === 'OMV_PREFERRED') return 'video';
                return null;
            }

            function trackInfo() {
                const bar = document.querySelector('ytmusic-player-bar');
                const metadata = navigator.mediaSession?.metadata;
                const title = metadata?.title?.trim() || bar?.querySelector('.title')?.textContent?.trim()
                    || document.title.replace(/\\s+-\\s+YouTube Music$/i, '').trim();
                const byline = bar?.querySelector('.byline, .subtitle');
                const artist = metadata?.artist?.trim() || byline?.querySelector('a')?.textContent?.trim()
                    || byline?.textContent?.split(/[•·\\n]/)[0]?.trim();
                const album = metadata?.album?.trim()
                    || byline?.querySelector('a[href*="/browse/MPRE"]')?.textContent?.trim() || '';
                const duration = mediaElement()?.duration;
                if (!title || !artist || !Number.isFinite(duration) || duration < 1) return null;
                const videoID = new URL(location.href).searchParams.get('v');
                const artistLinks = byline?.querySelectorAll('a[href*="/channel/"], a[href*="/browse/UC"]') || [];
                const artists = [...new Set([artist, ...[...artistLinks].map(link => link.textContent.trim()).filter(Boolean)])];
                return {title, artist, artists, album, duration: Math.round(duration), playbackMode: playbackMode(),
                    videoID: location.pathname === '/watch' && /^[A-Za-z0-9_-]{1,128}$/.test(videoID || '') ? videoID : null};
            }

            function songIdentity(track) {
                return track.videoID ? `video:${track.videoID}`
                    : `track:${JSON.stringify([track.title.toLowerCase(), track.artist.toLowerCase(), track.duration])}`;
            }

            function offsetIdentity(track) {
                const identity = songIdentity(track);
                return track.playbackMode ? `mode:${track.playbackMode}|${identity}` : identity;
            }

            function setOffset(value) {
                const track = trackInfo();
                if (!Number.isFinite(value) || !offsetTrackKey || !track
                    || !offsetTrackKey.startsWith(`${offsetIdentity(track)}|source:`)) return false;
                offset = Math.round(Math.max(-3_600_000, Math.min(3_600_000, value)));
                if (offset === defaultOffset) delete savedOffsets[offsetTrackKey];
                else savedOffsets[offsetTrackKey] = offset;
                updateTimingDisplay();
                overlay.querySelector('.lyrics-feedback').textContent = `Timing ${formatOffset(offset)}.`;
                window.webkit.messageHandlers.musicLyricsOffset.postMessage({trackKey: offsetTrackKey, milliseconds: offset});
                updateActiveLine(true);
                return true;
            }

            function lyricsTab() {
                const tabs = [...document.querySelectorAll(
                    'ytmusic-player-page [role="tab"], ytmusic-player-page tp-yt-paper-tab, ytmusic-player-page paper-tab'
                )];
                // shortcut: YouTube places Lyrics second in every language; revisit if it reorders player tabs.
                const item = tabs[1];
                if (!item) return false;
                return item.getAttribute('aria-selected') === 'true' || item.hasAttribute('selected')
                    || item.classList.contains('iron-selected');
            }

            function panelElement() { return document.querySelector('ytmusic-player-page #tab-renderer'); }

            function makeOverlay() {
                const element = document.createElement('section');
                element.id = 'music-custom-lyrics';
                element.setAttribute('aria-label', 'Synced Lyrics');
                element.innerHTML = `
                    <div class="lyrics-toolbar">
                        <button class="lyrics-toolbar-button lyrics-pronunciation-button" type="button" aria-label="Pronunciation" aria-pressed="false" title="Show pronunciation" hidden>
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 4H3v16h3M18 4h3v16h-3M8 16l4-8 4 8M9.5 13h5"/></svg>
                        </button>
                        <button class="lyrics-toolbar-button lyrics-translate-button" type="button" aria-label="Translate lyrics" aria-pressed="false" title="Show translation" ${translationEnabled ? '' : 'hidden'}>
                            <span class="lyrics-translation-spinner" aria-hidden="true"></span>
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12.9 15.1 10.4 12.6l.1-.1A17.5 17.5 0 0 0 14.1 6H17V4h-7V2H8v2H1v2h11.2A15.8 15.8 0 0 1 9 11.4 15.6 15.6 0 0 1 6.7 8h-2a17.7 17.7 0 0 0 3 4.6L2.7 17.5l1.4 1.4L9 14l3.1 3.1.8-2ZM18.5 9h-2L12 21h2l1.1-3h4.8l1.1 3h2L18.5 9Zm-2.7 7 1.7-4.6 1.7 4.6h-3.4Z"/></svg>
                        </button>
                        <button class="lyrics-settings-button lyrics-toolbar-button" type="button" aria-label="Lyric settings" aria-expanded="false" aria-haspopup="dialog" aria-controls="music-lyrics-settings" title="Lyric settings">
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19.14 12.94a7.8 7.8 0 0 0 .05-.94 7.8 7.8 0 0 0-.05-.94l2.03-1.58a.5.5 0 0 0 .12-.64l-1.92-3.32a.5.5 0 0 0-.61-.22l-2.39.96a7.3 7.3 0 0 0-1.63-.94l-.36-2.54A.5.5 0 0 0 13.88 2h-3.76a.5.5 0 0 0-.5.42L9.26 4.96c-.59.23-1.14.55-1.63.94l-2.4-.96a.5.5 0 0 0-.6.22L2.7 8.48a.5.5 0 0 0 .12.64l2.03 1.58a7.8 7.8 0 0 0-.05.94c0 .32.02.63.05.94l-2.03 1.58a.5.5 0 0 0-.12.64l1.92 3.32c.12.21.37.3.61.22l2.39-.96c.49.39 1.04.71 1.63.94l.36 2.54a.5.5 0 0 0 .5.42h3.76a.5.5 0 0 0 .5-.42l.36-2.54c.59-.23 1.14-.55 1.63-.94l2.4.96a.5.5 0 0 0 .6-.22l1.92-3.32a.5.5 0 0 0-.12-.64l-2.03-1.58ZM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Z"/></svg>
                        </button>
                        <div class="lyrics-settings-panel" id="music-lyrics-settings" role="dialog" aria-label="Lyric settings" hidden>
                            <h2>Lyric settings</h2>
                            <button type="button" class="lyrics-close-button" aria-label="Close lyric settings" title="Close">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m6 6 12 12M6 18 18 6"/></svg>
                            </button>
                            <div class="lyrics-offset-controls">
                                <button type="button" data-offset="-10" aria-label="Show lyrics earlier by 0.01 seconds" title="Earlier by 0.01 s">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M5 12h14"/></svg>
                                </button>
                                <label class="lyrics-offset-value">
                                    <input class="lyrics-offset-input" type="number" step="any" min="-3600" max="3600" required aria-label="Timing offset in seconds" title="Enter timing offset in seconds">
                                    <span aria-hidden="true">s</span>
                                </label>
                                <button type="button" data-offset="10" aria-label="Show lyrics later by 0.01 seconds" title="Later by 0.01 s">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>
                                </button>
                            </div>
                            <div class="lyrics-offset-footer">
                                <p class="lyrics-offset-note"><span class="lyrics-offset-scope">Saved for this song</span><br><span class="lyrics-offset-source"></span></p>
                                <button type="button" class="lyrics-reset-button" data-reset aria-label="Reset timing for this song, playback mode and lyric source">Reset</button>
                            </div>
                            <div class="lyrics-provider-section">
                                <label class="lyrics-provider-label" for="music-lyrics-provider">Provider</label>
                                <div class="lyrics-provider-control">
                                    <select class="lyrics-provider-select" id="music-lyrics-provider" aria-describedby="music-lyrics-provider-note"></select>
                                    <svg class="lyrics-provider-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>
                                </div>
                                <p class="lyrics-provider-note" id="music-lyrics-provider-note" role="status"></p>
                            </div>
                            <div class="lyrics-translation-section" ${translationEnabled ? '' : 'hidden'}>
                                <label class="lyrics-language-target" for="music-lyrics-language-target">Translate to</label>
                                <div class="lyrics-language-control"><select class="lyrics-language-select" id="music-lyrics-language-target" aria-describedby="music-lyrics-language-note" disabled><option>Loading languages…</option></select>
                                <svg class="lyrics-language-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg></div>
                                <p class="lyrics-language-note" id="music-lyrics-language-note" role="status"></p>
                                <p class="lyrics-language-help">One-time Apple language download.</p>
                                <button type="button" class="lyrics-language-system-settings" title="Open Translation Languages in System Settings">Manage downloaded languages<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 17 17 7M7 7h10v10"/></svg></button>
                            </div>
                        </div>
                    </div>
                    <div class="lyrics-scroll" tabindex="0" aria-label="Synced Lyrics"><div class="lyrics-lines" role="list"></div></div>
                    <div class="lyrics-message" role="status" hidden></div>
                    <footer class="lyrics-source">Synced Lyrics</footer>
                    <span class="lyrics-feedback" role="status"></span>
                `;
                const timingInput = element.querySelector('.lyrics-offset-input');
                const saveTimingInput = () => timingInput.reportValidity() && setOffset(timingInput.valueAsNumber * 1000);
                timingInput.addEventListener('change', saveTimingInput);
                timingInput.addEventListener('keydown', event => {
                    event.stopPropagation();
                    if (event.key === 'Enter') {
                        event.preventDefault();
                        if (saveTimingInput()) timingInput.blur();
                    }
                });
                element.querySelector('.lyrics-settings-button').addEventListener('click', event => {
                    const button = event.currentTarget;
                    const settings = element.querySelector('.lyrics-settings-panel');
                    settings.style.maxHeight = `${Math.max(0, element.clientHeight - 58)}px`;
                    settings.hidden = !settings.hidden;
                    button.setAttribute('aria-expanded', String(!settings.hidden));
                    if (translationEnabled && !settings.hidden) ensureLanguages().catch(error => translationNote(error.message));
                });
                element.querySelector('.lyrics-settings-panel .lyrics-close-button').addEventListener('click', () => closeSettings(true));
                element.querySelector('.lyrics-language-system-settings').addEventListener('click', () => {
                    window.webkit.messageHandlers.musicLyricsLanguage.postMessage({action: 'settings'})
                        .catch(error => translationNote(error.message));
                });
                element.querySelector('.lyrics-pronunciation-button').addEventListener('click', () => {
                    currentLanguagePreferences.pronunciation = !currentLanguagePreferences.pronunciation;
                    const enabled = currentLanguagePreferences.pronunciation;
                    preferenceSave = preferenceSave.then(() => window.webkit.messageHandlers.musicLyricsLanguage.postMessage({action: 'pronunciationPreference', enabled}))
                        .catch(error => { overlay.querySelector('.lyrics-feedback').textContent = `Could not save pronunciation: ${error.message}`; });
                    updatePronunciation();
                });
                element.querySelector('.lyrics-translate-button').addEventListener('click', () => {
                    if (!translationEnabled) return;
                    currentLanguagePreferences.translate = !currentLanguagePreferences.translate;
                    saveSongLanguagePreferences();
                    updateTranslation();
                });
                element.querySelector('.lyrics-language-select').addEventListener('change', () => {
                    languagePreferences.target = element.querySelector('.lyrics-language-select').value;
                    const preferences = {action: 'preferences', target: languagePreferences.target};
                    preferenceSave = preferenceSave.then(() => window.webkit.messageHandlers.musicLyricsLanguage.postMessage(preferences))
                        .catch(error => translationNote(`Could not save language: ${error.message}`));
                    if (currentLanguagePreferences.translate) updateTranslation();
                });
                document.addEventListener('click', event => {
                    if (!event.composedPath().includes(element.querySelector('.lyrics-toolbar'))) closeSettings();
                }, {capture: true, signal: lifetime.signal});
                document.addEventListener('keydown', event => {
                    if (event.key === 'Escape' && !element.querySelector('.lyrics-settings-panel').hidden) {
                        event.preventDefault();
                        event.stopPropagation();
                        if (document.activeElement === timingInput) {
                            timingInput.value = String(offset / 1000);
                            timingInput.blur();
                        } else closeSettings(true);
                    }
                }, {capture: true, signal: lifetime.signal});
                element.querySelectorAll('[data-offset]').forEach(button => button.addEventListener('click', () => {
                    setOffset(offset + Number(button.dataset.offset));
                }));
                element.querySelector('[data-reset]').addEventListener('click', () => setOffset(defaultOffset));
                element.querySelector('.lyrics-provider-select').addEventListener('change', event => {
                    const track = trackInfo();
                    if (!track || !currentResult || !offsetTrackKey.startsWith(`${offsetIdentity(track)}|source:`)) return;
                    const source = event.target.value;
                    if (source && !currentResult.alternatives.some(result => result.source === source)) return;
                    const identity = offsetIdentity(track);
                    if (source) savedProviders[identity] = source;
                    else delete savedProviders[identity];
                    window.webkit.messageHandlers.musicLyricsProvider.postMessage({trackKey: identity, source});
                    userScrollUntil = 0;
                    displayLyrics(currentResult, track);
                });
                const scroll = element.querySelector('.lyrics-scroll');
                for (const event of ['pointerenter', 'pointermove', 'pointerdown']) {
                    scroll.addEventListener(event, showSyncControls, {signal: lifetime.signal});
                }
                scroll.addEventListener('pointerleave', hideSyncControls, {signal: lifetime.signal});
                scroll.addEventListener('scroll', updateSyncControl, {passive: true, signal: lifetime.signal});
                scroll.addEventListener('focusin', cancelScroll, {signal: lifetime.signal});
                scroll.addEventListener('focusout', () => requestAnimationFrame(() => updateActiveLine(true)), {signal: lifetime.signal});
                for (const event of ['wheel', 'touchstart', 'pointerdown', 'keydown']) {
                    scroll.addEventListener(event, () => {
                        cancelScroll();
                        userScrollUntil = Date.now() + 2500;
                        scroll.querySelector('.lyrics-lines')?.classList.remove('is-following');
                    }, {passive: true});
                }
                resizeObserver.observe(scroll);
                timingInput.value = String(offset / 1000);
                return element;
            }

            function closeSettings(restoreFocus = false) {
                const settings = overlay?.querySelector('.lyrics-settings-panel');
                if (!settings || settings.hidden) return;
                settings.hidden = true;
                const button = overlay.querySelector('.lyrics-settings-button');
                button.setAttribute('aria-expanded', 'false');
                if (restoreFocus) button.focus({preventScroll: true});
            }

            function translationNote(message) {
                if (overlay) overlay.querySelector('.lyrics-language-note').textContent = message;
            }

            function hasNonLatin(text) {
                return Array.from(text).some(character => /\\p{L}/u.test(character) && !/\\p{Script=Latin}/u.test(character));
            }

            function updateLanguageButtons() {
                if (!overlay) return;
                const pronounce = overlay.querySelector('.lyrics-pronunciation-button');
                pronounce.hidden = !activeLines.some(line => !line.credit && hasNonLatin(line.text));
                pronounce.setAttribute('aria-pressed', String(currentLanguagePreferences.pronunciation));
                pronounce.title = currentLanguagePreferences.pronunciation ? 'Hide pronunciation' : 'Show pronunciation';
                const translate = overlay.querySelector('.lyrics-translate-button');
                translate.setAttribute('aria-pressed', String(currentLanguagePreferences.translate));
                translate.title = currentLanguagePreferences.translate ? 'Hide translation' : 'Show translation';
            }

            function restoreSongLanguagePreferences(track) {
                const identity = track ? songIdentity(track) : '';
                if (identity === languageTrackKey) return;
                languageTrackKey = identity;
                const saved = savedLanguagePreferences[identity] || {};
                currentLanguagePreferences.translate = translationEnabled && saved.translate === true;
                translationGeneration++;
                pronunciationGeneration++;
                translationNote('');
                updateLanguageButtons();
            }

            function saveSongLanguagePreferences() {
                if (!languageTrackKey) return;
                const preferences = {translate: currentLanguagePreferences.translate};
                if (preferences.translate) savedLanguagePreferences[languageTrackKey] = preferences;
                else delete savedLanguagePreferences[languageTrackKey];
                const payload = {...preferences, action: 'trackPreferences', trackKey: languageTrackKey};
                preferenceSave = preferenceSave.then(() => window.webkit.messageHandlers.musicLyricsLanguage.postMessage(payload))
                    .catch(error => translationNote(`Could not save song preferences: ${error.message}`));
                updateLanguageButtons();
            }

            function ensureLanguages() {
                if (!languagesReady) languagesReady = window.webkit.messageHandlers.musicLyricsLanguage.postMessage({action: 'options'})
                    .then(reply => {
                        if (lifetime.signal.aborted) return;
                        const select = overlay.querySelector('.lyrics-language-select');
                        select.replaceChildren(...reply.languages.map(item => new Option(item.name, item.code)));
                        languagePreferences.target = reply.target;
                        select.value = reply.target;
                        select.disabled = false;
                    }).catch(error => { languagesReady = null; throw error; });
                return languagesReady;
            }

            function embeddedTranslation(line, target) {
                try {
                    const language = new Intl.Locale(target).maximize();
                    for (const [code, text] of Object.entries(line.translations || {})) {
                        const candidate = new Intl.Locale(code).maximize();
                        if (candidate.language === language.language && candidate.script === language.script && typeof text === 'string') return text;
                    }
                } catch (_) {}
                return '';
            }

            function refreshLyricsLayout(update, preferredAnchor = null) {
                const scroll = overlay.querySelector('.lyrics-scroll');
                const lyrics = [...overlay.querySelectorAll('.lyrics-seek')];
                const middle = scroll.getBoundingClientRect().top + scroll.clientHeight / 2;
                const anchor = preferredAnchor || (Date.now() > userScrollUntil && overlay.querySelector('.lyrics-line.is-current .lyrics-seek'))
                    || lyrics.find(node => node.getBoundingClientRect().bottom >= middle) || lyrics.at(-1);
                const top = anchor?.getBoundingClientRect().top;
                cancelScroll();
                update();
                updateActiveLine(false, false, true);
                if (anchor) {
                    const target = scroll.scrollTop + anchor.getBoundingClientRect().top - top;
                    const list = overlay.querySelector('.lyrics-lines');
                    const maximum = scroll.scrollHeight - scroll.clientHeight;
                    // Keep room at the boundaries so shrinking content cannot clamp the reading position.
                    if (target < 0) list.style.paddingBlockStart = `${parseFloat(list.style.paddingBlockStart) - target}px`;
                    if (target > maximum) list.style.paddingBlockEnd = `${parseFloat(list.style.paddingBlockEnd) + target - maximum}px`;
                    scroll.scrollTop = Math.max(0, target);
                }
                updateSyncControl();
            }

            function paintTranslations(lines, texts) {
                refreshLyricsLayout(() => {
                    const rows = overlay.querySelectorAll('.lyrics-line');
                    for (const [index, line] of lines.entries()) {
                        if (line.credit) continue;
                        const node = rows[index].querySelector('.lyrics-translation');
                        node.textContent = texts[index] || '';
                        node.lang = languagePreferences.target || '';
                        node.hidden = !currentLanguagePreferences.translate || !node.textContent;
                    }
                });
            }

            function pronunciationWords(text, words) {
                if (!Array.isArray(words) || !words.length || words.length > 2000) return [];
                let previous = -1;
                const valid = words.every(word => {
                    const ordered = typeof word.word === 'string' && Number.isFinite(word.start_time) && Number.isFinite(word.end_time)
                        && word.start_time >= Math.max(0, previous) && word.end_time > word.start_time && word.end_time <= 3_602_000;
                    previous = word.start_time;
                    return ordered;
                });
                return valid && words.map(word => word.word).join('') === text ? words : [];
            }

            function paintPronunciation(lines, entries) {
                refreshLyricsLayout(() => {
                    const rows = overlay.querySelectorAll('.lyrics-line');
                    for (const [index, line] of lines.entries()) {
                        if (line.credit) continue;
                        const node = rows[index].querySelector('.lyrics-pronunciation');
                        const entering = node.hidden || node.getAnimations().length > 0;
                        const opacity = node.hidden ? 0 : Number(getComputedStyle(node).opacity);
                        node.getAnimations().forEach(animation => animation.cancel());
                        const entry = entries[index] || {text: '', words: []};
                        const words = pronunciationWords(entry.text, entry.words);
                        line.displayPronunciationWords = words;
                        node.replaceChildren();
                        if (words.length) appendTimedWords(node, words);
                        else node.textContent = entry.text || '';
                        node.hidden = !currentLanguagePreferences.pronunciation || !node.textContent;
                        if (entering && !node.hidden && !reducedMotion.matches) {
                            node.animate([{opacity}, {opacity: 1}], {duration: 180, easing: 'ease-out'});
                        }
                    }
                });
                startWordSyncLoop();
            }

            async function updatePronunciation() {
                const token = ++pronunciationGeneration;
                const lines = activeLines;
                updateLanguageButtons();
                cancelScroll();
                if (!currentLanguagePreferences.pronunciation) {
                    const animations = [];
                    overlay.querySelectorAll('.lyrics-pronunciation').forEach(node => {
                        const opacity = Number(getComputedStyle(node).opacity);
                        node.getAnimations().forEach(animation => animation.cancel());
                        if (!node.hidden && !reducedMotion.matches) {
                            animations.push(node.animate([{opacity}, {opacity: 0}], {duration: 180, fill: 'forwards'}));
                        }
                    });
                    if (animations.length) await Promise.allSettled(animations.map(animation => animation.finished));
                    if (token === pronunciationGeneration && !lifetime.signal.aborted && activeLines === lines) {
                        paintPronunciation(lines, []);
                    }
                    animations.forEach(animation => animation.cancel());
                    return;
                }
                const key = JSON.stringify(lines.map(line => [line.text, line.words, line.pronunciation, line.pronunciationWords, line.credit]));
                if (pronunciationCache.has(key)) { paintPronunciation(lines, pronunciationCache.get(key)); return; }
                const entries = lines.map(line => ({
                    text: !line.credit && hasNonLatin(line.text) ? line.pronunciation || '' : '',
                    words: line.pronunciationWords || []
                }));
                paintPronunciation(lines, entries);
                if (!lines.length) return;
                const needed = lines.map((line, i) => i).filter(i => !lines[i].credit && hasNonLatin(lines[i].text)
                    && (!entries[i].text || (!pronunciationWords(entries[i].text, entries[i].words).length && lines[i].words?.length)));
                try {
                    if (needed.length) {
                        const reply = await window.webkit.messageHandlers.musicLyricsLanguage.postMessage({action: 'pronunciation',
                            texts: needed.map(i => lines[i].text), words: needed.map(i => lines[i].words || []),
                            pronunciations: needed.map(i => entries[i].text)});
                        if (token !== pronunciationGeneration || lifetime.signal.aborted || activeLines !== lines) return;
                        needed.forEach((index, i) => entries[index] = reply.lines?.[i] || entries[index]);
                    }
                    if (token !== pronunciationGeneration || lifetime.signal.aborted || activeLines !== lines) return;
                    paintPronunciation(lines, entries);
                    pronunciationCache.set(key, entries);
                    if (pronunciationCache.size > 30) pronunciationCache.delete(pronunciationCache.keys().next().value);
                } catch (_) {
                    if (token === pronunciationGeneration && !lifetime.signal.aborted && activeLines === lines) {
                        overlay.querySelector('.lyrics-feedback').textContent = 'Pronunciation is unavailable for some lines.';
                    }
                }
            }

            async function updateTranslation() {
                const token = ++translationGeneration;
                const lines = activeLines;
                window.webkit.messageHandlers.musicLyricsLanguage.postMessage({action: 'cancel'}).catch(() => {});
                updateLanguageButtons();
                paintTranslations(lines, []);
                const button = overlay.querySelector('.lyrics-translate-button');
                button.setAttribute('aria-busy', 'false');
                translationNote('');
                if (!translationEnabled || !currentLanguagePreferences.translate || !lines.length) return;
                button.setAttribute('aria-busy', 'true');
                translationNote('Checking languages…');
                try {
                    await ensureLanguages();
                    if (token !== translationGeneration || lifetime.signal.aborted || activeLines !== lines) return;
                    const target = languagePreferences.target;
                    const key = JSON.stringify([target, lines.map(line => [line.text, line.translations, line.credit])]);
                    if (translationCache.has(key)) {
                        const cached = translationCache.get(key);
                        paintTranslations(lines, cached.texts); translationNote(cached.note); return;
                    }
                    const texts = lines.map(line => line.credit ? '' : embeddedTranslation(line, target));
                    paintTranslations(lines, texts);
                    const needed = lines.map((line, i) => i).filter(i => !lines[i].credit && !texts[i]);
                    let note = 'Translation from lyric source.';
                    if (needed.length) {
                        const reply = await window.webkit.messageHandlers.musicLyricsLanguage.postMessage({action: 'translate', target, token, texts: needed.map(i => lines[i].text)});
                        if (token !== translationGeneration || lifetime.signal.aborted || activeLines !== lines || reply.status === 'cancelled') return;
                        needed.forEach((index, i) => texts[index] = reply.texts?.[i] || '');
                        note = reply.message || 'Translated on your Mac.';
                        paintTranslations(lines, texts);
                        translationNote(note);
                        if (reply.message) return;
                    }
                    translationNote(note);
                    translationCache.set(key, {texts, note});
                    if (translationCache.size > 30) translationCache.delete(translationCache.keys().next().value);
                } catch (error) {
                    if (token === translationGeneration && !lifetime.signal.aborted && activeLines === lines) translationNote(`Translation unavailable: ${error.message}`);
                } finally {
                    if (token === translationGeneration && !lifetime.signal.aborted) button.setAttribute('aria-busy', 'false');
                }
            }

            function formatOffset(value) {
                const seconds = value / 1000;
                return `${seconds > 0 ? '+' : ''}${seconds.toFixed(value % 10 === 0 ? 2 : 3)} s`;
            }

            function updateTimingDisplay() {
                overlay.querySelector('.lyrics-offset-input').value = String(offset / 1000);
                const source = overlay.querySelector('.lyrics-offset-source').textContent;
                const timing = activeLines.some(line => line.words?.length > 0)
                    ? 'Word-by-word' : activeLines.some(line => line.time != null) ? 'Line-by-line' : 'No timing';
                const adjustment = offset === 0 ? '' : ` · ${formatOffset(offset).replace(/^[+-]/, '')} ${offset < 0 ? 'earlier' : 'later'}`;
                overlay.querySelector('.lyrics-source').textContent = `Lyrics from ${source} · ${timing}${adjustment}`;
            }

            function cancelContentTransition() {
                contentAnimation?.cancel();
                contentAnimation = null;
            }

            function showMessage(message, action, details) {
                if (!overlay) return;
                cancelContentTransition();
                cancelScroll();
                stopWordSyncLoop();
                activeLines = [];
                translationGeneration++;
                pronunciationGeneration++;
                translationNote('');
                activeIndex = -1;
                panel?.classList.remove('music-custom-lyrics-active');
                overlay.classList.add('is-notice');
                const box = overlay.querySelector('.lyrics-message');
                const restoreFocus = box.contains(document.activeElement);
                const loading = !!loadingKey && loadingKey === trackKey && !completedKey;
                const list = overlay.querySelector('.lyrics-scroll');
                list.setAttribute('aria-busy', String(loading));
                list.hidden = true;
                overlay.querySelector('.lyrics-lines').replaceChildren();
                box.replaceChildren();
                const text = document.createElement('div');
                text.className = 'lyrics-message-text';
                text.textContent = message;
                if (loading) {
                    const spinner = document.createElement('span');
                    spinner.className = 'lyrics-spinner';
                    spinner.setAttribute('aria-hidden', 'true');
                    text.prepend(spinner);
                }
                box.append(text);
                if (action || details) {
                    const actions = document.createElement('div');
                    actions.className = 'lyrics-message-actions';
                    if (details) {
                        const info = document.createElement('button');
                        info.type = 'button';
                        info.className = 'lyrics-info-button';
                        info.setAttribute('aria-label', 'Show error details');
                        info.setAttribute('aria-controls', 'music-custom-lyrics-error-details');
                        info.setAttribute('aria-expanded', 'false');
                        info.title = 'Show error details';
                        info.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 7.75h.01"/></svg>';
                        const detailText = document.createElement('div');
                        detailText.id = 'music-custom-lyrics-error-details';
                        detailText.className = 'lyrics-error-text';
                        detailText.hidden = true;
                        detailText.textContent = details;
                        info.addEventListener('click', () => {
                            const expanded = detailText.hidden;
                            detailText.hidden = !expanded;
                            info.setAttribute('aria-expanded', String(expanded));
                            info.setAttribute('aria-label', expanded ? 'Hide error details' : 'Show error details');
                            info.title = expanded ? 'Hide error details' : 'Show error details';
                        });
                        actions.append(info);
                        box.append(actions, detailText);
                    }
                    if (action) {
                        const button = document.createElement('button');
                        button.type = 'button'; button.textContent = action.label;
                        button.disabled = Date.now() < retryAfter;
                        button.addEventListener('click', action.run);
                        actions.append(button);
                        if (button.disabled) setTimeout(() => { button.disabled = Date.now() < retryAfter; }, retryAfter - Date.now() + 50);
                    }
                    if (!details) box.append(actions);
                }
                box.hidden = false;
                if (restoreFocus) {
                    box.tabIndex = -1;
                    box.focus({preventScroll: true});
                }
            }

            function parseLRC(value) {
                const lines = [];
                for (const raw of value.split(/\\r?\\n/)) {
                    const times = [...raw.matchAll(/\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]/g)];
                    const text = raw.replace(/\\[[^\\]]+\\]/g, '').trim();
                    if (!text || !times.length) continue;
                    for (const match of times) {
                        const fraction = match[3] ? Number(`0.${match[3]}`) : 0;
                        lines.push({time: (Number(match[1]) * 60 + Number(match[2]) + fraction) * 1000, text});
                    }
                }
                lines.sort((a, b) => a.time - b.time);
                return lines.map(line => ({time: line.time, text: line.text, words: []}));
            }

            function parseYRC(value) {
                const lines = [];
                for (const raw of value.split(/\\r?\\n/)) {
                    const trimmed = raw.trim();
                    if (!trimmed) continue;
                    if (trimmed.startsWith('{')) {
                        try {
                            const creditObj = JSON.parse(trimmed);
                            const text = (creditObj.c || []).map(item => item.tx || '').join('').trim();
                            if (text) lines.push({time: creditObj.t ?? 0, text, words: [], credit: true});
                        } catch (_) {}
                        continue;
                    }
                    const lineMatch = trimmed.match(/^\\[(\\d+),(\\d+)\\](.*)$/);
                    if (!lineMatch) continue;
                    const lineStart = Number(lineMatch[1]);
                    const lineDuration = Number(lineMatch[2]);
                    const rest = lineMatch[3];

                    const words = [];
                    const tokenRegex = /\\((\\d+),(\\d+),\\d+\\)([^(]*)/g;
                    let tokenMatch;
                    let fullText = '';
                    while ((tokenMatch = tokenRegex.exec(rest)) !== null) {
                        const wordStart = Number(tokenMatch[1]);
                        const wordDur = Number(tokenMatch[2]);
                        const wordText = tokenMatch[3];
                        fullText += wordText;
                        words.push({
                            word: wordText,
                            start_time: wordStart,
                            end_time: wordStart + wordDur
                        });
                    }
                    const text = fullText.trim();
                    if (text) {
                        lines.push({
                            time: lineStart,
                            duration: lineDuration,
                            endTime: lineStart + lineDuration,
                            text,
                            words,
                            credit: false
                        });
                    }
                }
                lines.sort((a, b) => a.time - b.time);
                return lines;
            }

            function appendTimedWords(container, words) {
                for (const word of words) {
                    const segments = Array.from(graphemeSegmenter.segment(word.word), item => item.segment);
                    let first = 0;
                    while (first < segments.length && segments[first].trim() === '') {
                        container.append(document.createTextNode(segments[first++]));
                    }
                    let last = segments.length;
                    while (last > first && segments[last - 1].trim() === '') last--;
                    const wordSpan = document.createElement('span');
                    wordSpan.className = 'lyrics-word';
                    for (const segment of segments.slice(first, last)) {
                        if (segment.trim() === '') {
                            wordSpan.append(document.createTextNode(segment));
                        } else {
                            const letter = document.createElement('span');
                            letter.className = 'lyrics-letter';
                            letter.textContent = segment;
                            wordSpan.append(letter);
                        }
                    }
                    wordSpan.dataset.start = String(word.start_time);
                    wordSpan.dataset.end = String(word.end_time);
                    container.append(wordSpan);
                    for (const segment of segments.slice(last)) {
                        container.append(document.createTextNode(segment));
                    }
                }
            }

            function lyricPauses(lines) {
                const pauses = [];
                let coveredUntil = 0;
                let known = true;
                for (const [index, line] of lines.entries()) {
                    if (line.credit) continue;
                    if (!Number.isFinite(line.time)) return [];
                    if (known && line.time - coveredUntil >= 5000) {
                        pauses.push({index, start: coveredUntil, end: line.time});
                    }
                    // An unknown vocal ending cannot safely establish an instrumental gap.
                    if (!Number.isFinite(line.endTime) || line.endTime <= line.time) known = false;
                    else coveredUntil = Math.max(coveredUntil, line.endTime);
                }
                return pauses;
            }

            function renderLines(lines) {
                cancelScroll();
                stopWordSyncLoop();
                activeLines = lines;
                activeIndex = -1;
                overlay.classList.remove('is-notice');
                if (!overlay.hidden && lyricsTab()) panel.classList.add('music-custom-lyrics-active');
                const synchronized = lines.some(line => line.time != null);
                overlay.querySelector('.lyrics-toolbar').hidden = !synchronized;
                updateTimingDisplay();
                const list = overlay.querySelector('.lyrics-lines');
                const scroll = overlay.querySelector('.lyrics-scroll');
                scroll.setAttribute('aria-busy', 'false');
                const message = overlay.querySelector('.lyrics-message');
                const restoreFocus = message.contains(document.activeElement);
                list.replaceChildren();
                list.classList.toggle('is-plain', !synchronized);
                list.style.paddingBlock = '';
                message.hidden = true;
                scroll.hidden = false;
                const pauses = new Map(lyricPauses(lines).map(pause => [pause.index, pause]));
                for (const [index, line] of lines.entries()) {
                    const pause = pauses.get(index);
                    if (pause) {
                        const indicator = document.createElement('p');
                        indicator.className = 'lyrics-pause';
                        indicator.setAttribute('aria-hidden', 'true');
                        indicator.dataset.start = String(pause.start);
                        indicator.dataset.end = String(pause.end);
                        indicator.setAttribute('role', 'listitem');
                        indicator.setAttribute('aria-label', 'Instrumental break before next lyric');
                        for (let dot = 0; dot < 3; dot++) {
                            const span = document.createElement('span');
                            span.setAttribute('aria-hidden', 'true');
                            indicator.append(span);
                        }
                        list.append(indicator);
                    }
                    const row = document.createElement('p');
                    row.className = line.credit ? 'lyrics-line is-credit' : 'lyrics-line';
                    row.setAttribute('role', 'listitem');
                    row.dataset.index = String(index);
                    if (Number.isFinite(line.time) && !line.credit) {
                        const button = document.createElement('button');
                        button.type = 'button';
                        button.className = 'lyrics-seek';
                        button.title = 'Jump to this line';
                        button.addEventListener('click', () => {
                            const media = mediaElement();
                            if (!media) return;
                            const time = Math.max(0, Math.min(media.duration, (line.time + offset) / 1000));
                            if (!Number.isFinite(time)) return;
                            try {
                                media.currentTime = time;
                                userScrollUntil = 0;
                                updateActiveLine(true);
                            } catch (_) {
                                overlay.querySelector('.lyrics-source').textContent = 'Playback is not ready to seek. Try again.';
                            }
                        });
                        if (line.words && line.words.length > 0) {
                            appendTimedWords(button, line.words);
                        } else {
                            button.textContent = line.text;
                        }
                        const align = document.createElement('button');
                        align.type = 'button';
                        align.className = 'lyrics-align';
                        align.title = 'Sync this line to now';
                        align.setAttribute('aria-label', `Sync this line to now: ${line.text}`);
                        align.innerHTML = '<svg aria-hidden="true" viewBox="0 0 25 25" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M13.5 4.5H12.5C8.08172 4.5 4.5 8.08172 4.5 12.5C4.5 15.6631 6.33576 18.3975 9 19.6958M11.5 20.5H12.5C16.9183 20.5 20.5 16.9183 20.5 12.5C20.5 9.33688 18.6642 6.60253 16 5.30423" stroke="currentColor" stroke-width="1.2"/><path d="M14 17.5619L11.5 20.5L14.5 23.0619M11 7.43811L13.5 4.50001L10.5 1.93811" stroke="currentColor" stroke-width="1.2"/></svg>';
                        align.addEventListener('click', () => {
                            const media = mediaElement();
                            if (!media || !Number.isFinite(media.currentTime) || media.currentTime < 0 || media.currentTime > media.duration) return;
                            if (!setOffset(media.currentTime * 1000 - line.time)) return;
                            userScrollUntil = 0;
                            updateActiveLine(true);
                            overlay.querySelector('.lyrics-feedback').textContent = `Lyrics aligned to this line. Timing ${formatOffset(offset)}.`;
                        });
                        row.append(button, align);
                    } else {
                        row.textContent = line.text;
                    }
                    if (!line.credit) {
                        for (const kind of ['pronunciation', 'translation']) {
                            const auxiliary = document.createElement('span');
                            auxiliary.className = `lyrics-${kind}`;
                            auxiliary.dir = 'auto';
                            auxiliary.hidden = true;
                            row.append(auxiliary);
                        }
                    }
                    list.append(row);
                }
                // Reset after the scroller is visible; writes while hidden cannot clear its saved position.
                scroll.scrollTo({top: 0, behavior: 'instant'});
                updateActiveLine(true, true);
                updateSyncControl();
                if (restoreFocus) scroll.focus({preventScroll: true});
                startWordSyncLoop();
                updatePronunciation();
                updateTranslation();
            }

            function cancelScroll() {
                cancelAnimationFrame(scrollFrame);
                scrollFrame = 0;
            }

            function scrollToPosition(scroll, target, immediate = false, duration = 420) {
                target = Math.max(0, Math.min(scroll.scrollHeight - scroll.clientHeight, target));
                if (scrollFrame && Math.abs(target - scrollTarget) < 1 && !reducedMotion.matches && !immediate) return;
                cancelScroll();
                scrollTarget = target;
                const start = scroll.scrollTop;
                if (immediate || reducedMotion.matches || Math.abs(target - start) < 1) {
                    scroll.scrollTop = target;
                    return;
                }
                const started = performance.now();
                function step(now) {
                    const progress = reducedMotion.matches ? 1 : Math.min(1, Math.max(0, (now - started) / duration));
                    scroll.scrollTop = start + (target - start) * progress * progress * (3 - 2 * progress);
                    scrollFrame = progress < 1 ? requestAnimationFrame(step) : 0;
                }
                scrollFrame = requestAnimationFrame(step);
            }

            function updateWordSpans(container, words, time) {
                const wordSpans = container?.querySelectorAll('.lyrics-word');
                if (!wordSpans?.length) return;
                for (let i = 0; i < words.length; i++) {
                    const w = words[i];
                    const span = wordSpans[i];
                    if (!span) continue;
                    const letters = span.querySelectorAll('.lyrics-letter');
                    const completed = span.classList.contains('is-sung') && !span.classList.contains('is-current');
                    if (time >= w.end_time || (completed && time >= w.end_time - 80)) {
                        if (!completed) {
                            letters.forEach(letter => {
                                if (letter.style.getPropertyValue('--word-progress') !== '100%') {
                                    letter.style.setProperty('--word-progress', '100%');
                                }
                            });
                            span.classList.add('is-sung');
                            span.classList.remove('is-current');
                        }
                    } else if (time >= w.start_time && time < w.end_time) {
                        const progress = Math.max(0, Math.min(1, (time - w.start_time) / (w.end_time - w.start_time)));
                        const letterProgress = progress * letters.length;
                        letters.forEach((letter, index) => {
                            const fill = Math.max(0, Math.min(1, letterProgress - index));
                            const value = `${fill * 100}%`;
                            if (letter.style.getPropertyValue('--word-progress') !== value) {
                                letter.style.setProperty('--word-progress', value);
                            }
                        });
                        span.classList.add('is-sung', 'is-current');
                    } else {
                        letters.forEach(letter => {
                            if (letter.style.getPropertyValue('--word-progress') !== '0%') {
                                letter.style.setProperty('--word-progress', '0%');
                            }
                        });
                        span.classList.remove('is-sung', 'is-current');
                    }
                }
            }

            function updateActiveWords(time) {
                if (activeIndex < 0 || !activeLines[activeIndex]) return;
                const line = activeLines[activeIndex];
                const row = overlay?.querySelectorAll('.lyrics-line')[activeIndex];
                if (!row) return;
                updateWordSpans(row.querySelector('.lyrics-seek'), line.words || [], time);
                updateWordSpans(row.querySelector('.lyrics-pronunciation'), line.displayPronunciationWords || [], time);
            }

            function updatePause(time, holdLayout = false) {
                let active = null;
                for (const indicator of overlay.querySelectorAll('.lyrics-pause')) {
                    const end = Number(indicator.dataset.end);
                    const visible = time >= Number(indicator.dataset.start) && time < end;
                    const retained = time >= Number(indicator.dataset.start) && time < end + 650;
                    const fade = Math.max(0, Math.min(1, (time - end) / 650));
                    indicator.style.opacity = String(1 - fade * fade * (3 - 2 * fade));
                    indicator.dataset.active = String(visible);
                    if (!holdLayout) {
                        indicator.classList.toggle('is-visible', retained);
                        indicator.setAttribute('aria-hidden', String(!retained));
                    }
                    if (!visible) {
                        if (retained) indicator.querySelectorAll('span').forEach(dot => { dot.style.opacity = '1'; });
                        continue;
                    }
                    active = indicator;
                    indicator.querySelectorAll('span').forEach((dot, index) => {
                        const fill = Math.max(0, Math.min(1, (time - (end - 3000 + index * 1000)) / 1000));
                        dot.style.opacity = String(.3 + .7 * fill);
                        const pulse = reducedMotion.matches ? 1 : 1 + .2 * Math.sin(time / 2000 * Math.PI * 2 - index * .5);
                        dot.style.transform = `scale(${pulse})`;
                    });
                }
                return active;
            }

            function updateActiveLine(forceScroll = false, immediate = false, refreshLayout = false) {
                if (!overlay || overlay.hidden || !activeLines.length) return;
                if (activeLines.every(line => line.time == null)) return;
                const current = mediaElement()?.currentTime;
                if (!Number.isFinite(current)) return;
                let next = -1;
                const time = current * 1000 - offset;
                for (let index = 0; index < activeLines.length; index++) {
                    if (activeLines[index].credit) continue;
                    if (activeLines[index].time == null || activeLines[index].time <= time) next = index;
                    else break;
                }
                const scroll = overlay.querySelector('.lyrics-scroll');
                const holdSync = syncScrollPaused || document.activeElement?.matches('.lyrics-align:focus-visible, .lyrics-seek:focus-visible');
                const list = overlay.querySelector('.lyrics-lines');
                const following = !holdSync && Date.now() > userScrollUntil;
                const followChanged = list.classList.contains('is-following') !== following;
                list.classList.toggle('is-following', following);
                const previousPause = overlay.querySelector('.lyrics-pause[data-active="true"]');
                const layoutChanged = [...overlay.querySelectorAll('.lyrics-pause')].some(indicator => {
                    const visible = time >= Number(indicator.dataset.start) && time < Number(indicator.dataset.end) + 650;
                    return visible !== indicator.classList.contains('is-visible');
                });
                const pauseEnded = previousPause && time >= Number(previousPause.dataset.end);
                const preservedPauseLayout = (layoutChanged || pauseEnded) && !refreshLayout && !holdSync;
                if (preservedPauseLayout) {
                    const anchor = Date.now() > userScrollUntil && next >= 0
                        ? overlay.querySelectorAll('.lyrics-line')[next].querySelector('.lyrics-seek') : null;
                    refreshLyricsLayout(() => updatePause(time), anchor);
                }
                const pause = updatePause(time, holdSync);
                const pauseChanged = pause !== previousPause;
                if (next === activeIndex && !pauseChanged && !preservedPauseLayout && !forceScroll && !refreshLayout && !followChanged) {
                    updateActiveWords(time);
                    return;
                }
                activeIndex = next;
                const rows = overlay.querySelectorAll('.lyrics-line');
                rows.forEach((row, index) => {
                    const isPast = index < activeIndex || (pause && index === activeIndex);
                    row.classList.toggle('is-fading', !!(isPast && following && !followChanged && row.classList.contains('is-current')));
                    row.classList.toggle('is-past', isPast);
                    const isCurrent = index === activeIndex && !pause;
                    row.classList.toggle('is-current', isCurrent);
                    if (isCurrent) {
                        row.setAttribute('aria-current', 'true');
                    } else {
                        row.removeAttribute('aria-current');
                        if (index < activeIndex) {
                            row.querySelectorAll('.lyrics-word').forEach(s => {
                                s.classList.add('is-sung');
                                s.classList.remove('is-current');
                            });
                        } else {
                            row.querySelectorAll('.lyrics-word').forEach(s => {
                                s.classList.remove('is-sung', 'is-current');
                            });
                        }
                    }
                });
                updateActiveWords(time);
                const first = rows[0].querySelector('.lyrics-seek') || rows[0];
                const second = rows[1]?.querySelector('.lyrics-seek') || rows[1] || first;
                const topAnchor = 16 + first.offsetHeight + 24 + second.offsetHeight + (rows[1] ? 24 : 0);
                if (!preservedPauseLayout && !holdSync && (refreshLayout || forceScroll || Date.now() > userScrollUntil)) {
                    list.style.paddingBlockStart = `${topAnchor}px`;
                    const last = rows[rows.length - 1];
                    list.style.paddingBlockEnd = `${Math.max(0, scroll.clientHeight - (last.querySelector('.lyrics-seek') || last).offsetHeight - topAnchor)}px`;
                }
                if (activeIndex < 0 && !pause) {
                    cancelScroll();
                    if (!holdSync) scroll.scrollTo({top: 0, behavior: 'instant'});
                    return;
                }
                if (!holdSync && !refreshLayout && (forceScroll || Date.now() > userScrollUntil)) {
                    const row = pause || rows[activeIndex];
                    const target = row.querySelector('.lyrics-seek') || row;
                    const bounds = target.getBoundingClientRect();
                    const verticalTransform = new DOMMatrix(getComputedStyle(target).transform).m42;
                    scrollToPosition(scroll, scroll.scrollTop + bounds.top - verticalTransform
                        - scroll.getBoundingClientRect().top - topAnchor, immediate, pauseChanged ? 700 : 650);
                }
            }

            let wordFrame = 0;
            function startWordSyncLoop() {
                if (wordFrame || lifetime.signal.aborted) return;
                const hasWords = activeLines.some(line => line.words?.length || line.displayPronunciationWords?.length);
                if (!hasWords && !overlay?.querySelector('.lyrics-pause')) return;
                function step() {
                    wordFrame = 0;
                    if (lifetime.signal.aborted) return;
                    const media = mediaElement();
                    if (media && !media.paused && !media.ended && !overlay?.hidden && !document.hidden) {
                        updateActiveLine();
                        wordFrame = requestAnimationFrame(step);
                    }
                }
                wordFrame = requestAnimationFrame(step);
            }

            function stopWordSyncLoop() {
                if (wordFrame) {
                    cancelAnimationFrame(wordFrame);
                    wordFrame = 0;
                }
            }

            function cancelLookup() {
                window.webkit.messageHandlers.musicLyricsLookup.postMessage({action: 'cancel'}).catch(() => {});
            }

            function readLyrics(record, synchronized = true, artists = []) {
                if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('invalid-response');
                let yrcLines = [];
                if (typeof record.yrcLyrics === 'string' && record.yrcLyrics.trim()) {
                    try { yrcLines = parseYRC(record.yrcLyrics); } catch (_) {}
                }
                const lyricsFileLines = Array.isArray(record.lyricsFileLines) ? record.lyricsFileLines : [];
                const synced = lyricsFileLines.length ? lyricsFileLines : yrcLines.length ? yrcLines
                    : (typeof record.syncedLyrics === 'string' ? parseLRC(record.syncedLyrics) : []);
                const plain = typeof record.plainLyrics === 'string'
                    ? record.plainLyrics.split(/\\r?\\n/).map(text => ({time: null, text: text.trim()})).filter(line => line.text)
                    : [];
                const lines = synchronized && synced.length ? synced
                    : plain.length ? plain : synced.map(line => ({time: null, text: line.text}));
                const normalizeName = value => value.normalize('NFKC').toLowerCase().replace(/\\s+/g, ' ').trim();
                const performerNames = new Set(artists.map(normalizeName));
                return {instrumental: record.instrumental === true,
                    lines: lines.filter(line => typeof line.text === 'string'
                        && /[^\\s\\p{Default_Ignorable_Code_Point}]/u.test(line.text)).map(line => {
                        const text = line.text.normalize('NFKC');
                        const performer = text.match(/^\\(([^()]+)\\)$/u)?.[1];
                        // Match declared artists only; parenthesized words may be sung vocals.
                        return {...line, credit: line.credit || creditPattern.test(text)
                            || (performer != null && performerNames.has(normalizeName(performer)))};
                    })};
            }

            function automaticLyrics(result, netEaseLines) {
                if (result.source !== 'NetEase' || !result.lines.some(line => !line.credit && line.words?.length)) return result;
                function profile(lines) {
                    const texts = lines.filter(line => !line.credit && Number.isFinite(line.time)).map(line => line.text);
                    const letters = texts.join('').match(/\\p{L}/gu) || [];
                    const count = script => letters.filter(letter => script.test(letter)).length;
                    const normalized = new Set(texts.map(text => text.normalize('NFKC').toLowerCase()
                        .replace(/[^\\p{L}\\p{M}]/gu, '')).filter(Boolean));
                    return {normalized, enough: letters.length >= 60 && normalized.size >= 3,
                        latin: count(/\\p{Script=Latin}/u) / letters.length >= .95,
                        han: count(/\\p{Script=Han}/u) / letters.length >= .9
                            && !count(/[\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Hangul}]/u)};
                }
                const original = profile(result.lines);
                if (!original.enough || !original.han) return result;
                const candidates = result.alternatives.flatMap(item => item.source === 'NetEase'
                    ? [item, {source: item.source, lines: netEaseLines}] : [item])
                    .map(item => ({item, ...profile(item.lines)}))
                    .filter(candidate => candidate.enough && candidate.latin);
                // Require matching vocals from different providers; Latin alone may be a romanization.
                // shortcut: compare whole lines; use token alignment if differing line breaks need support.
                const supported = candidates.filter(candidate => candidates.some(other => {
                    if (candidate.item.source === other.item.source) return false;
                    const common = [...candidate.normalized].filter(text => other.normalized.has(text)).length;
                    return common >= 3 && common / candidate.normalized.size >= .6
                        && common / other.normalized.size >= .6;
                }));
                return supported.find(candidate => candidate.item.lines.some(line => !line.credit && line.words?.length))?.item
                    || supported[0]?.item || result;
            }

            async function fetchLyrics(track, key) {
                if (cache.has(key)) return cache.get(key);
                const reply = await window.webkit.messageHandlers.musicLyricsLookup.postMessage(track);
                if (lifetime.signal.aborted || trackKey !== key || reply.status === 'cancelled') return null;
                retryAfter = Date.now() + Math.max(0, reply.retryAfter || 0) * 1000;
                if (reply.status === 'unavailable') throw new Error(reply.message);
                const result = reply.record ? {...readLyrics(reply.record, reply.record.synchronized, track.artists), source: reply.record.source} : null;
                if (result) {
                    result.alternatives = (reply.alternatives || [reply.record]).map(record => ({
                        ...readLyrics(record, record.synchronized, track.artists), source: record.source
                    })).filter(result => result.lines.some(line => Number.isFinite(line.time) && !line.credit));
                    if (!result.lines.some(line => Number.isFinite(line.time) && !line.credit)) {
                        const fallback = result.alternatives.find(item => item.lines.some(line => line.words?.length && !line.credit))
                            || result.alternatives[0];
                        if (fallback) Object.assign(result, fallback);
                    }
                    const netEase = (reply.alternatives || [reply.record]).find(record => record.source === 'NetEase');
                    const netEaseLines = netEase ? readLyrics({...netEase, yrcLyrics: '', lyricsFileLines: []},
                        netEase.synchronized, track.artists).lines : [];
                    Object.assign(result, automaticLyrics(result, netEaseLines));
                }
                cache.set(key, result);
                if (cache.size > 30) cache.delete(cache.keys().next().value);
                return result;
            }

            function displayLyrics(result, track) {
                const identity = offsetIdentity(track);
                restoreSongLanguagePreferences(track);
                const preferred = savedProviders[identity] || '';
                const selected = result.alternatives.find(item => item.source === preferred) || result;
                const select = overlay.querySelector('.lyrics-provider-select');
                select.replaceChildren(new Option(`Automatic · ${result.source}`, ''));
                for (const item of result.alternatives) {
                    const timing = item.lines.some(line => line.words?.length) ? 'Word-by-word' : 'Line-by-line';
                    select.add(new Option(`${item.source} · ${timing}`, item.source));
                }
                const unavailable = preferred && selected.source !== preferred;
                if (unavailable) {
                    const option = new Option(`${preferred} · Unavailable`, preferred);
                    option.disabled = true;
                    select.add(option);
                }
                select.value = preferred;
                overlay.querySelector('.lyrics-provider-note').textContent = unavailable
                    ? `${preferred} is unavailable. Showing ${selected.source} for now.`
                    : preferred ? 'Saved for this song.'
                    : result.alternatives.length > 1 ? 'Best available match.'
                    : 'No other providers matched.';
                offsetTrackKey = `${identity}|source:${selected.source}`;
                defaultOffset = selected.source === 'lrcmux (KuGou)' ? \(Self.kugouDefaultOffset) : 0;
                offset = savedOffsets[offsetTrackKey] ?? defaultOffset;
                overlay.querySelector('.lyrics-offset-source').textContent = selected.source;
                overlay.querySelector('.lyrics-offset-scope').textContent = track.playbackMode
                    ? `Saved for ${track.playbackMode === 'video' ? 'Video' : 'Song'} mode` : 'Saved for this song';
                renderLines(selected.lines);
            }

            async function loadTrack(force = false) {
                const track = trackInfo();
                if (!track) {
                    if (trackKey) cancelLookup();
                    restoreSongLanguagePreferences(null);
                    trackKey = '';
                    loadingKey = '';
                    completedKey = '';
                    offsetTrackKey = '';
                    offset = 0;
                    currentResult = null;
                    activeLines = [];
                    showMessage('Waiting for track information…');
                    return;
                }
                const identity = offsetIdentity(track);
                const key = `${identity}|${track.title.toLocaleLowerCase()}|${track.artist.toLocaleLowerCase()}|${track.duration}|${JSON.stringify([track.album.toLocaleLowerCase(), track.artists])}`;
                if (force) cache.delete(key);
                if (!force && key === trackKey && (activeLines.length || loadingKey === key || completedKey === key)) return;
                if (key !== trackKey) {
                    cancelLookup();
                    restoreSongLanguagePreferences(track);
                    closeSettings();
                    userScrollUntil = 0;
                    trackKey = key;
                    completedKey = '';
                    activeLines = [];
                    activeIndex = -1;
                }
                loadingKey = key;
                completedKey = '';
                offsetTrackKey = '';
                offset = 0;
                currentResult = null;
                overlay.querySelector('.lyrics-offset-input').value = String(offset / 1000);
                overlay.querySelector('.lyrics-offset-source').textContent = '';
                showMessage('Looking for synced lyrics…');
                try {
                    const result = await fetchLyrics(track, key);
                    if (lifetime.signal.aborted || trackKey !== key || !overlay) return;
                    completedKey = key;
                    const retry = {label: 'Try Again', run: () => loadTrack(true)};
                    if (!result) {
                        showMessage('No matching lyrics.', retry);
                        return;
                    }
                    if (result.instrumental) {
                        showMessage('This track is listed as instrumental.', retry);
                        return;
                    }
                    if (!result.lines.some(line => Number.isFinite(line.time) && !line.credit)) {
                        showMessage('No synced lyrics for this song.', retry);
                        return;
                    }
                    if (!reducedMotion.matches && !document.hidden && !overlay.hidden && lyricsTab()) {
                        contentAnimation = panel.animate([{opacity: 1}, {opacity: 0}], {
                            duration: 100, easing: 'ease-out', fill: 'forwards'
                        });
                        await contentAnimation.finished.catch(() => {});
                        if (lifetime.signal.aborted || trackKey !== key) return;
                    }
                    currentResult = result;
                    displayLyrics(result, track);
                    cancelContentTransition();
                    if (!reducedMotion.matches && !document.hidden && !overlay.hidden && lyricsTab()) {
                        contentAnimation = panel.animate([{opacity: 0}, {opacity: 1}], {
                            duration: 240, easing: 'cubic-bezier(.16,1,.3,1)'
                        });
                    }
                } catch (error) {
                    if (lifetime.signal.aborted || trackKey !== key) return;
                    completedKey = key;
                    showMessage('Couldn’t load synced lyrics.', {
                        label: 'Try Again', run: () => loadTrack(true)
                    }, error?.message || 'No additional provider details.');
                } finally {
                    if (loadingKey === key) loadingKey = '';
                }
            }

            function schedule() {
                if (frame || lifetime.signal.aborted) return;
                frame = requestAnimationFrame(() => {
                    frame = 0;
                    const nextPanel = panelElement();
                    const active = !!nextPanel && lyricsTab();
                    if (!active) {
                        hideSyncControls();
                        cancelContentTransition();
                        cancelScroll();
                        if (panel) panel.classList.remove('music-custom-lyrics-active');
                        if (overlay) overlay.hidden = true;
                        return;
                    }
                    if (nextPanel !== panel || overlay?.parentElement !== nextPanel || nextPanel.firstElementChild !== overlay) {
                        panel?.classList.remove('music-custom-lyrics-active');
                        panel = nextPanel;
                        overlay ??= makeOverlay();
                        panel.prepend(overlay);
                    }
                    const returning = overlay.hidden;
                    overlay.hidden = false;
                    loadTrack();
                    panel.classList.toggle('music-custom-lyrics-active', activeLines.length > 0);
                    updateActiveLine(returning, returning);
                    startWordSyncLoop();
                });
            }

            const resizeObserver = new ResizeObserver(() => {
                if (overlay) overlay.querySelectorAll('.lyrics-settings-panel').forEach(menu => {
                    menu.style.maxHeight = `${Math.max(0, overlay.clientHeight - 58)}px`;
                });
                updateActiveLine(true);
                updateSyncControl();
            });
            const observer = new MutationObserver(records => {
                const relevant = records.some(record => {
                    if (overlay && (record.target === overlay || overlay.contains(record.target))) return false;
                    if (record.target === panel && record.type === 'attributes' && record.attributeName === 'class') return false;
                    if (overlay?.isConnected && record.target === panel && record.type === 'childList'
                        && [...record.addedNodes, ...record.removedNodes].every(node => node === overlay)) return false;
                    const target = record.target.nodeType === Node.ELEMENT_NODE ? record.target : record.target.parentElement;
                    const player = 'ytmusic-player-page, ytmusic-player-bar';
                    return target?.closest(player) || [...record.addedNodes, ...record.removedNodes]
                        .some(node => node.matches?.(player) || node.querySelector?.(player));
                });
                if (relevant) schedule();
            });
            observer.observe(document.documentElement, {
                subtree: true, childList: true, characterData: true, attributes: true,
                attributeFilter: ['aria-selected', 'selected', 'class', 'hidden', 'href', 'playback-mode', 'video-mode']
            });
            for (const event of ['play', 'loadedmetadata', 'durationchange', 'emptied']) {
                document.addEventListener(event, schedule, {capture: true, signal: lifetime.signal});
            }
            for (const event of ['timeupdate', 'seeking', 'seeked', 'pause']) {
                document.addEventListener(event, () => updateActiveLine(), {capture: true, signal: lifetime.signal});
            }
            document.addEventListener('visibilitychange', () => {
                if (document.hidden) cancelContentTransition();
                else schedule();
            }, {signal: lifetime.signal});
            window.musicCustomLyrics = {translationStatus(token, phase) {
                if (token !== translationGeneration || !currentLanguagePreferences.translate || lifetime.signal.aborted) return;
                if (overlay?.querySelector('.lyrics-translate-button').getAttribute('aria-busy') !== 'true') return;
                const messages = {checking: 'Checking languages…', download: 'Waiting for language download…', translating: 'Translating…'};
                if (messages[phase]) translationNote(messages[phase]);
            }, stop() {
                clearTimeout(syncResumeTimer);
                stopWordSyncLoop();
                cancelLookup();
                cancelScroll();
                cancelContentTransition();
                lifetime.abort();
                observer.disconnect();
                resizeObserver.disconnect();
                cancelAnimationFrame(frame);
                panel?.classList.remove('music-custom-lyrics-active');
                overlay?.remove();
                style.remove();
                delete window.musicCustomLyrics;
            }};
            schedule();
        })();
        """
    }
}
