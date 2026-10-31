import Foundation
import CoreFoundation
import WebKit

@MainActor
final class MusicLyrics: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    private let defaults: UserDefaults
    private let enabledKey = "MusicCustomLyricsEnabled"
    private let offsetsKey = "MusicLyricsOffsetsByTrack"
    private var installedScript: WKUserScript?
    private let provider: MusicLyricsProvider
    private var lookupTask: Task<Void, Never>?

    init(provider: MusicLyricsProvider? = nil, defaults: UserDefaults = .standard) {
        self.provider = provider ?? MusicLyricsProvider()
        self.defaults = defaults
        super.init()
    }

    func connect(to controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: "musicLyricsLookup")
        controller.add(self, contentWorld: .defaultClient, name: "musicLyricsOffset")
    }

    func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard isYouTubeMusic(message.frameInfo) else {
            replyHandler(nil, "Lyrics are available only on YouTube Music.")
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

    private func validOffsetKey(_ key: String) -> Bool {
        if key.hasPrefix("video:") {
            return key.range(of: #"^video:[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
        }
        return key.hasPrefix("track:") && key.count > 6 && key.utf8.count <= 2048
    }

    private func validOffset(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let milliseconds = number as? Int, (-10_000...10_000).contains(milliseconds) else { return nil }
        return milliseconds
    }

    var trackOffsets: [String: Int] {
        (defaults.dictionary(forKey: offsetsKey) ?? [:]).reduce(into: [:]) { result, entry in
            guard validOffsetKey(entry.key), let value = validOffset(entry.value), value != 0 else { return }
            result[entry.key] = value
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "musicLyricsOffset", isYouTubeMusic(message.frameInfo),
              let body = message.body as? [String: Any], let key = body["trackKey"] as? String,
              validOffsetKey(key), let value = validOffset(body["milliseconds"]) else { return }
        var offsets = trackOffsets
        if value == 0 { offsets.removeValue(forKey: key) } else { offsets[key] = value }
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
        let script = WKUserScript(source: Self.source(offsets: offsets),
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

    private static func source(offsets: String) -> String {
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
                    min-height: 0; flex: 1 1 auto;
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
                    display: flex; justify-content: flex-end; align-items: center;
                    min-height: 34px; position: absolute; top: 8px; left: 0; right: 14px; z-index: 2;
                    pointer-events: none;
                }
                #music-custom-lyrics .lyrics-settings-button {
                    display: grid; place-items: center; width: 34px; height: 34px;
                    padding: 0; border: 0; border-radius: 50%; color: rgba(255,255,255,.78);
                    background: transparent; cursor: pointer; pointer-events: auto;
                }
                #music-custom-lyrics .lyrics-settings-button:hover,
                #music-custom-lyrics .lyrics-settings-button:focus-visible { color: #fff; background: rgba(255,255,255,.12); }
                #music-custom-lyrics .lyrics-settings-button:focus-visible,
                #music-custom-lyrics button:focus-visible { outline: 2px solid rgba(255,255,255,.78); outline-offset: 2px; }
                #music-custom-lyrics .lyrics-settings-button svg { width: 19px; height: 19px; fill: currentColor; }
                #music-custom-lyrics .lyrics-settings-panel {
                    position: absolute; top: 42px; right: 0; z-index: 3;
                    width: 224px; max-width: 100%; box-sizing: border-box;
                    padding: 12px; border: 0; border-radius: 8px; pointer-events: auto;
                    background: var(--ytmusic-menu-background, #282828); color: #f5f5f5;
                    box-shadow: 0 8px 24px rgba(0,0,0,.32);
                }
                #music-custom-lyrics .lyrics-settings-panel h2 {
                    margin: 0 36px 12px 0; font-size: 14px; font-weight: 500; line-height: 20px;
                }
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
                #music-custom-lyrics .lyrics-offset-controls output {
                    text-align: center; font-size: 16px; font-weight: 500;
                    line-height: 24px; font-variant-numeric: tabular-nums;
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
                    overscroll-behavior: contain; scrollbar-width: auto; scroll-behavior: auto;
                    mask-image: linear-gradient(to bottom, transparent, #000 12%, #000 88%, transparent), linear-gradient(#000, #000);
                    mask-size: calc(100% - 14px) 100%, 14px 100%;
                    mask-position: left top, right top; mask-repeat: no-repeat;
                }
                #music-custom-lyrics .lyrics-scroll:has(.lyrics-lines.is-plain) { mask-image: none; }
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
                    margin: 0; color: rgba(245,245,245,.24); font-size: clamp(20px, 1.7vw, 26px);
                    font-weight: 700; line-height: 1.28; letter-spacing: -.018em;
                    transition: transform .6s cubic-bezier(.16,1,.3,1);
                }
                #music-custom-lyrics .lyrics-line + .lyrics-line { margin-top: 24px; }
                #music-custom-lyrics .lyrics-line.is-credit + .lyrics-line.is-credit { margin-top: 0; }
                #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-line {
                    transform: scale(.94); transform-origin: left center;
                }
                #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-line.is-current {
                    color: #fff; transform: scale(1);
                }
                #music-custom-lyrics .lyrics-lines .lyrics-line.is-credit {
                    font-size: 14px; font-weight: 400; line-height: 1.5; letter-spacing: normal;
                    color: rgba(245,245,245,.65); transform: none;
                }
                #music-custom-lyrics .lyrics-lines.is-plain .lyrics-line { color: #f5f5f5; }
                #music-custom-lyrics .lyrics-seek {
                    display: block; width: 100%; min-height: 32px; padding: 2px 0;
                    border: 0; color: inherit; background: transparent; text-align: left;
                    font: inherit; line-height: inherit; letter-spacing: inherit;
                    cursor: pointer; -webkit-user-select: none;
                }
                #music-custom-lyrics .lyrics-seek:hover { background: rgba(255,255,255,.04); }
                #music-custom-lyrics .lyrics-seek:focus-visible { outline-offset: -2px; border-radius: 4px; }
                #music-custom-lyrics .lyrics-line:not(.is-current) .lyrics-seek:focus-visible { color: rgba(245,245,245,.8); }
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
                    margin-bottom: 12px; padding: 10px 16px;
                    border-bottom: 1px solid rgba(255,255,255,.16);
                    background: transparent;
                }
                #music-custom-lyrics.is-notice .lyrics-toolbar,
                #music-custom-lyrics.is-notice .lyrics-scroll,
                #music-custom-lyrics.is-notice .lyrics-source { display: none; }
                #music-custom-lyrics.is-notice .lyrics-message {
                    display: flex; align-items: center; justify-content: space-between;
                    gap: 12px; text-align: left; font-size: 13px; color: #f5f5f5;
                }
                #music-custom-lyrics.is-notice .lyrics-message div { flex: 1; min-width: 0; }
                #music-custom-lyrics.is-notice .lyrics-message button { flex-shrink: 0; margin: 0; }
                #music-custom-lyrics .lyrics-source {
                    min-height: 19px; color: rgba(255,255,255,.65); font-size: 11px;
                    padding: 8px 0; text-align: center; letter-spacing: .01em;
                }
                @media (prefers-reduced-motion: reduce) {
                    #music-custom-lyrics .lyrics-line { transition: none; }
                    #music-custom-lyrics .lyrics-lines:not(.is-plain) .lyrics-line { transform: none; }
                    #music-custom-lyrics .lyrics-scroll { scroll-behavior: auto !important; }
                }
            `;
            document.documentElement.append(style);

            const cache = new Map();
            const creditPattern = /^(?:作词|作詞|作曲|编曲|編曲|词|詞|曲|작사|작곡|편곡|composer|lyricist|arranger|producer|lyrics(?:\\s+by)?|music(?:\\s+by)?|words(?:\\s+by)?|written\\s+by|composed\\s+by|arranged\\s+by|produced\\s+by|penulis|pencipta)\\s*[:：]/iu;
            let overlay = null;
            let panel = null;
            let trackKey = '';
            let loadingKey = '';
            let completedKey = '';
            let activeLines = [];
            let activeIndex = -1;
            const savedOffsets = \(offsets);
            let offsetTrackKey = '';
            let offset = 0;
            let retryAfter = 0;
            let userScrollUntil = 0;
            let frame = 0;
            let scrollFrame = 0;
            let scrollTarget = 0;
            const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

            function mediaElement() {
                const media = [...document.querySelectorAll('video, audio')];
                return media.find(item => !item.paused && !item.ended && Number.isFinite(item.duration))
                    || media.find(item => Number.isFinite(item.duration));
            }

            function trackInfo() {
                const bar = document.querySelector('ytmusic-player-bar');
                const metadata = navigator.mediaSession?.metadata;
                const title = metadata?.title?.trim() || bar?.querySelector('.title')?.textContent?.trim()
                    || document.title.replace(/\\s+-\\s+YouTube Music$/i, '').trim();
                const byline = bar?.querySelector('.byline, .subtitle');
                const artist = metadata?.artist?.trim() || byline?.querySelector('a')?.textContent?.trim()
                    || byline?.textContent?.split(/[•·\\n]/)[0]?.trim();
                const duration = mediaElement()?.duration;
                if (!title || !artist || !Number.isFinite(duration) || duration < 1) return null;
                const videoID = new URL(location.href).searchParams.get('v');
                const artistLinks = byline?.querySelectorAll('a[href*="/channel/"], a[href*="/browse/UC"]') || [];
                const artists = [...new Set([artist, ...[...artistLinks].map(link => link.textContent.trim()).filter(Boolean)])];
                return {title, artist, artists, duration: Math.round(duration),
                    videoID: location.pathname === '/watch' && /^[A-Za-z0-9_-]{1,128}$/.test(videoID || '') ? videoID : null};
            }

            function offsetIdentity(track) {
                return track.videoID ? `video:${track.videoID}`
                    : `track:${JSON.stringify([track.title.toLowerCase(), track.artist.toLowerCase(), track.duration])}`;
            }

            function setOffset(value) {
                if (!offsetTrackKey) return;
                offset = Math.max(-10_000, Math.min(10_000, value));
                if (offset === 0) delete savedOffsets[offsetTrackKey];
                else savedOffsets[offsetTrackKey] = offset;
                overlay.querySelector('.lyrics-settings-panel output').textContent = formatOffset(offset);
                window.webkit.messageHandlers.musicLyricsOffset.postMessage({trackKey: offsetTrackKey, milliseconds: offset});
                updateActiveLine(true);
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
                        <button class="lyrics-settings-button" type="button" aria-label="Lyric settings" aria-expanded="false" title="Lyric settings">
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19.14 12.94a7.8 7.8 0 0 0 .05-.94 7.8 7.8 0 0 0-.05-.94l2.03-1.58a.5.5 0 0 0 .12-.64l-1.92-3.32a.5.5 0 0 0-.61-.22l-2.39.96a7.3 7.3 0 0 0-1.63-.94l-.36-2.54A.5.5 0 0 0 13.88 2h-3.76a.5.5 0 0 0-.5.42L9.26 4.96c-.59.23-1.14.55-1.63.94l-2.4-.96a.5.5 0 0 0-.6.22L2.7 8.48a.5.5 0 0 0 .12.64l2.03 1.58a7.8 7.8 0 0 0-.05.94c0 .32.02.63.05.94l-2.03 1.58a.5.5 0 0 0-.12.64l1.92 3.32c.12.21.37.3.61.22l2.39-.96c.49.39 1.04.71 1.63.94l.36 2.54a.5.5 0 0 0 .5.42h3.76a.5.5 0 0 0 .5-.42l.36-2.54c.59-.23 1.14-.55 1.63-.94l2.4.96a.5.5 0 0 0 .6-.22l1.92-3.32a.5.5 0 0 0-.12-.64l-2.03-1.58ZM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Z"/></svg>
                        </button>
                        <div class="lyrics-settings-panel" role="dialog" aria-label="Lyric timing" hidden>
                            <h2>Lyric timing</h2>
                            <button type="button" class="lyrics-close-button" aria-label="Close lyric timing" title="Close">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m6 6 12 12M6 18 18 6"/></svg>
                            </button>
                            <div class="lyrics-offset-controls">
                                <button type="button" data-offset="-250" aria-label="Show lyrics earlier by 0.25 seconds" title="Earlier by 0.25 s">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M5 12h14"/></svg>
                                </button>
                                <output aria-label="Timing offset" aria-live="polite"></output>
                                <button type="button" data-offset="250" aria-label="Show lyrics later by 0.25 seconds" title="Later by 0.25 s">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>
                                </button>
                            </div>
                            <div class="lyrics-offset-footer">
                                <p class="lyrics-offset-note">Saved for this song</p>
                                <button type="button" class="lyrics-reset-button" data-reset aria-label="Reset timing for this song">Reset</button>
                            </div>
                        </div>
                    </div>
                    <div class="lyrics-scroll" tabindex="0" aria-label="Synced Lyrics"><div class="lyrics-lines" role="list"></div></div>
                    <div class="lyrics-message" role="status" hidden></div>
                    <footer class="lyrics-source">Synced Lyrics</footer>
                `;
                element.querySelector('.lyrics-settings-button').addEventListener('click', event => {
                    const button = event.currentTarget;
                    const settings = element.querySelector('.lyrics-settings-panel');
                    settings.hidden = !settings.hidden;
                    button.setAttribute('aria-expanded', String(!settings.hidden));
                });
                element.querySelector('.lyrics-close-button').addEventListener('click', () => closeSettings(true));
                document.addEventListener('click', event => {
                    if (!event.composedPath().includes(element.querySelector('.lyrics-toolbar'))) closeSettings();
                }, {capture: true, signal: lifetime.signal});
                document.addEventListener('keydown', event => {
                    if (event.key === 'Escape' && !element.querySelector('.lyrics-settings-panel').hidden) {
                        event.preventDefault();
                        event.stopPropagation();
                        closeSettings(true);
                    }
                }, {capture: true, signal: lifetime.signal});
                element.querySelectorAll('[data-offset]').forEach(button => button.addEventListener('click', () => {
                    setOffset(offset + Number(button.dataset.offset));
                }));
                element.querySelector('[data-reset]').addEventListener('click', () => setOffset(0));
                const scroll = element.querySelector('.lyrics-scroll');
                for (const event of ['wheel', 'touchstart', 'pointerdown', 'keydown']) {
                    scroll.addEventListener(event, () => {
                        cancelScroll();
                        userScrollUntil = Date.now() + 2500;
                    }, {passive: true});
                }
                resizeObserver.observe(scroll);
                element.querySelector('.lyrics-settings-panel output').textContent = formatOffset(offset);
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

            function formatOffset(value) {
                const seconds = value / 1000;
                return `${seconds > 0 ? '+' : ''}${seconds.toFixed(2)} s`;
            }

            function showMessage(message, action) {
                if (!overlay) return;
                cancelScroll();
                activeLines = [];
                activeIndex = -1;
                panel?.classList.remove('music-custom-lyrics-active');
                overlay.classList.add('is-notice');
                const box = overlay.querySelector('.lyrics-message');
                const list = overlay.querySelector('.lyrics-scroll');
                list.hidden = true;
                overlay.querySelector('.lyrics-lines').replaceChildren();
                box.replaceChildren();
                const text = document.createElement('div');
                text.textContent = message;
                box.append(text);
                if (action) {
                    const button = document.createElement('button');
                    button.type = 'button'; button.textContent = action.label;
                    button.disabled = Date.now() < retryAfter;
                    button.addEventListener('click', action.run);
                    box.append(button);
                    if (button.disabled) setTimeout(() => { button.disabled = Date.now() < retryAfter; }, retryAfter - Date.now() + 50);
                }
                box.hidden = false;
            }

            function parseLRC(value) {
                const result = [];
                for (const raw of value.split(/\\r?\\n/)) {
                    const times = [...raw.matchAll(/\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]/g)];
                    const text = raw.replace(/\\[[^\\]]+\\]/g, '').trim();
                    if (!text || !times.length) continue;
                    for (const match of times) {
                        const fraction = match[3] ? Number(`0.${match[3]}`) : 0;
                        result.push({time: (Number(match[1]) * 60 + Number(match[2]) + fraction) * 1000, text});
                    }
                }
                return result.sort((a, b) => a.time - b.time);
            }

            function renderLines(lines, source) {
                cancelScroll();
                activeLines = lines;
                activeIndex = -1;
                overlay.classList.remove('is-notice');
                if (!overlay.hidden && lyricsTab()) panel.classList.add('music-custom-lyrics-active');
                const synchronized = lines.some(line => line.time != null);
                overlay.querySelector('.lyrics-toolbar').hidden = !synchronized;
                overlay.querySelector('.lyrics-source').textContent = synchronized
                    ? `Lyrics from ${source}` : `Lyrics from ${source} · Unsynchronized`;
                const list = overlay.querySelector('.lyrics-lines');
                const scroll = overlay.querySelector('.lyrics-scroll');
                const message = overlay.querySelector('.lyrics-message');
                list.replaceChildren();
                list.classList.toggle('is-plain', !synchronized);
                list.style.paddingBlock = '';
                message.hidden = true;
                scroll.hidden = false;
                for (const [index, line] of lines.entries()) {
                    const row = document.createElement('p');
                    row.className = line.credit ? 'lyrics-line is-credit' : 'lyrics-line';
                    row.setAttribute('role', 'listitem');
                    row.dataset.index = String(index);
                    if (Number.isFinite(line.time) && !line.credit) {
                        const button = document.createElement('button');
                        button.type = 'button';
                        button.className = 'lyrics-seek';
                        button.textContent = line.text;
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
                        row.append(button);
                    } else {
                        row.textContent = line.text;
                    }
                    list.append(row);
                }
                // Reset after the scroller is visible; writes while hidden cannot clear its saved position.
                scroll.scrollTo({top: 0, behavior: 'instant'});
                updateActiveLine(true);
            }

            function cancelScroll() {
                cancelAnimationFrame(scrollFrame);
                scrollFrame = 0;
            }

            function scrollToPosition(scroll, target) {
                target = Math.max(0, Math.min(scroll.scrollHeight - scroll.clientHeight, target));
                if (scrollFrame && Math.abs(target - scrollTarget) < 1 && !reducedMotion.matches) return;
                cancelScroll();
                scrollTarget = target;
                const start = scroll.scrollTop;
                if (reducedMotion.matches || Math.abs(target - start) < 1) {
                    scroll.scrollTop = target;
                    return;
                }
                const started = performance.now();
                function step(now) {
                    const progress = reducedMotion.matches ? 1 : Math.min(1, Math.max(0, (now - started) / 650));
                    scroll.scrollTop = start + (target - start) * (1 - (1 - progress) ** 3);
                    scrollFrame = progress < 1 ? requestAnimationFrame(step) : 0;
                }
                scrollFrame = requestAnimationFrame(step);
            }

            function updateActiveLine(forceScroll = false) {
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
                if (next === activeIndex && !forceScroll) return;
                activeIndex = next;
                const rows = overlay.querySelectorAll('.lyrics-line');
                const scroll = overlay.querySelector('.lyrics-scroll');
                const list = overlay.querySelector('.lyrics-lines');
                rows.forEach((row, index) => {
                    row.classList.toggle('is-current', index === activeIndex);
                    if (index === activeIndex) row.setAttribute('aria-current', 'true');
                    else row.removeAttribute('aria-current');
                });
                list.style.paddingBlockStart = `${Math.max(0, (scroll.clientHeight - rows[0].offsetHeight) / 2)}px`;
                list.style.paddingBlockEnd = `${Math.max(0, (scroll.clientHeight - rows[rows.length - 1].offsetHeight) / 2)}px`;
                if (activeIndex < 0) {
                    cancelScroll();
                    scroll.scrollTo({top: 0, behavior: 'instant'});
                    return;
                }
                if (forceScroll || Date.now() > userScrollUntil) {
                    const bounds = rows[activeIndex].getBoundingClientRect();
                    scrollToPosition(scroll, scroll.scrollTop + bounds.top + bounds.height / 2
                        - scroll.getBoundingClientRect().top - scroll.clientHeight / 2);
                }
            }

            function cancelLookup() {
                window.webkit.messageHandlers.musicLyricsLookup.postMessage({action: 'cancel'}).catch(() => {});
            }

            function readLyrics(record, synchronized = true, artists = []) {
                if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('invalid-response');
                const synced = typeof record.syncedLyrics === 'string' ? parseLRC(record.syncedLyrics) : [];
                const plain = typeof record.plainLyrics === 'string'
                    ? record.plainLyrics.split(/\\r?\\n/).map(text => ({time: null, text: text.trim()})).filter(line => line.text)
                    : [];
                const lines = synchronized && synced.length ? synced
                    : plain.length ? plain : synced.map(line => ({time: null, text: line.text}));
                const normalizeName = value => value.normalize('NFKC').toLowerCase().replace(/\\s+/g, ' ').trim();
                const performerNames = new Set(artists.map(normalizeName));
                return {instrumental: record.instrumental === true,
                    lines: lines.map(line => {
                        const text = line.text.normalize('NFKC');
                        const performer = text.match(/^\\(([^()]+)\\)$/u)?.[1];
                        // Match declared artists only; parenthesized words may be sung vocals.
                        return {...line, credit: creditPattern.test(text)
                            || (performer != null && performerNames.has(normalizeName(performer)))};
                    })};
            }

            async function fetchLyrics(track, key) {
                if (cache.has(key)) return cache.get(key);
                const reply = await window.webkit.messageHandlers.musicLyricsLookup.postMessage(track);
                if (lifetime.signal.aborted || trackKey !== key || reply.status === 'cancelled') return null;
                retryAfter = Date.now() + Math.max(0, reply.retryAfter || 0) * 1000;
                if (reply.status === 'unavailable') throw new Error(reply.message);
                const result = reply.record ? {...readLyrics(reply.record, reply.record.synchronized, track.artists), source: reply.record.source} : null;
                cache.set(key, result);
                if (cache.size > 30) cache.delete(cache.keys().next().value);
                return result;
            }

            async function loadTrack(force = false) {
                const track = trackInfo();
                if (!track) {
                    if (trackKey) cancelLookup();
                    trackKey = '';
                    loadingKey = '';
                    completedKey = '';
                    offsetTrackKey = '';
                    offset = 0;
                    activeLines = [];
                    showMessage('Waiting for track information…');
                    return;
                }
                const identity = offsetIdentity(track);
                const key = `${identity}|${track.title.toLocaleLowerCase()}|${track.artist.toLocaleLowerCase()}|${track.duration}|${JSON.stringify(track.artists)}`;
                if (force) cache.delete(key);
                if (!force && key === trackKey && (activeLines.length || loadingKey === key || completedKey === key)) return;
                if (key !== trackKey) {
                    cancelLookup();
                    closeSettings();
                    userScrollUntil = 0;
                    trackKey = key;
                    offsetTrackKey = identity;
                    offset = savedOffsets[identity] ?? 0;
                    overlay.querySelector('.lyrics-settings-panel output').textContent = formatOffset(offset);
                    completedKey = '';
                    activeLines = [];
                    activeIndex = -1;
                }
                loadingKey = key;
                completedKey = '';
                showMessage('Looking for lyrics…');
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
                    if (!result.lines.length) {
                        showMessage('No readable lyrics.', retry);
                        return;
                    }
                    renderLines(result.lines, result.source);
                } catch (error) {
                    if (lifetime.signal.aborted || trackKey !== key) return;
                    completedKey = key;
                    const message = error.message || 'Couldn’t load lyrics.';
                    showMessage(message, {
                        label: 'Try Again', run: () => loadTrack(true)
                    });
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
                    updateActiveLine(returning);
                });
            }

            const resizeObserver = new ResizeObserver(() => updateActiveLine(true));
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
                attributeFilter: ['aria-selected', 'selected', 'class', 'hidden', 'href']
            });
            for (const event of ['play', 'loadedmetadata', 'durationchange', 'emptied']) {
                document.addEventListener(event, schedule, {capture: true, signal: lifetime.signal});
            }
            for (const event of ['timeupdate', 'seeking', 'seeked']) {
                document.addEventListener(event, () => updateActiveLine(), {capture: true, signal: lifetime.signal});
            }
            window.musicCustomLyrics = {stop() {
                cancelLookup();
                cancelScroll();
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
