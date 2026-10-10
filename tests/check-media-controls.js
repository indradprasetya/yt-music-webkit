// Run with: node tests/check-media-controls.js
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const source = readFileSync(join(__dirname, '../Music/main.swift'), 'utf8');
const script = source.match(/WKUserScript\(source: """([\s\S]*?)""", injectionTime/)[1];
const handlers = new Map();
const registrations = [];
class MediaSession {
    setActionHandler(action, handler) {
        assert.equal(this, mediaSession);
        registrations.push([action, handler]);
        handlers.set(action, handler);
    }
}
let mediaSession = new MediaSession();
const document = new EventTarget();
let elements = [];
let audio = null;
document.querySelector = selector => {
    assert.equal(selector, '#movie_player', 'Volume controls must not depend on the old player-bar layout');
    return audio;
};
document.querySelectorAll = () => elements;
document.activeElement = null;
const messages = [];
let controlsChanged;
const window = { webkit: { messageHandlers: { playbackState: { postMessage: state => messages.push(state) } } } };
const install = (hostname, navigator, protocol = 'https:') => runInNewContext(script, {
    location: { hostname, protocol }, navigator, MediaSession, document, window, queueMicrotask, Event,
    MutationObserver: class {
        constructor(callback) { controlsChanged = callback; }
        observe() {}
    },
});

const original = mediaSession.setActionHandler;
install('accounts.google.com', { mediaSession });
assert.equal(mediaSession.setActionHandler, original);
install('music.youtube.com', { mediaSession }, 'http:');
assert.equal(mediaSession.setActionHandler, original);
assert.equal(window.musicPlayback, undefined, 'Never install the bridge on a different origin');
install('music.youtube.com', {});
install('music.youtube.com', { mediaSession });
// WebKit may recreate an idle session's JS wrapper before first playback.
mediaSession = new MediaSession();

// Check first playback and re-registration on later tracks, before any timer runs.
for (let track = 0; track < 2; track++) {
    for (const action of ['seekbackward', 'seekforward', 'previoustrack', 'nexttrack', 'play', 'pause', 'seekto']) {
        const handler = () => action;
        mediaSession.setActionHandler(action, handler);
        if (action === 'seekbackward' || action === 'seekforward') {
            assert.equal(handlers.get(action), null, `${action} must be disabled immediately`);
        } else {
            assert.equal(handlers.get(action), handler);
            assert.equal(handlers.get(action)(), action);
        }
        mediaSession.setActionHandler(action, null);
        assert.equal(handlers.get(action), null);
    }
}
assert(!registrations.some(([action, handler]) =>
    (action === 'seekbackward' || action === 'seekforward') && handler !== null),
    'Interval skipping must never be advertised, even transiently');
console.log('PASS: first playback and later tracks keep next/previous controls without enabling interval skips');

(async () => {
    const bridge = window.musicPlayback;
    const state = () => messages.at(-1);
    assert.equal(state().playpause, false);
    assert.equal(await bridge.run('playpause'), false, 'No player means no playback commands');
    const player = { readyState: 1, paused: true, ended: false, volume: 0.5, muted: false, error: null };
    elements = [player];
    let volume = 50;
    audio = {
        getVolume() { return volume; },
        setVolume(value) { volume = value; player.volume = volume / 100 * 0.8; },
        isMuted() { return player.muted; },
        mute() { player.muted = true; },
        unMute() { player.muted = false; },
    };
    const calls = [];
    for (const action of ['play', 'pause', 'nexttrack', 'previoustrack']) {
        mediaSession.setActionHandler(action, details => {
            assert.equal(details.action, action);
            calls.push(action);
            if (action === 'play' || action === 'pause') player.paused = action === 'pause';
        });
    }
    assert.equal(state().playpause, true);
    assert.equal(await bridge.run('playpause'), true);
    assert.equal(state().paused, false);
    assert.equal(await bridge.run('playpause'), true);
    assert.equal(state().paused, true);
    await bridge.run('nexttrack');
    await bridge.run('previoustrack');
    assert.deepEqual(calls, ['play', 'pause', 'nexttrack', 'previoustrack']);
    mediaSession.setActionHandler('nexttrack', () => calls.push('replacement'));
    await bridge.run('nexttrack');
    assert.equal(calls.at(-1), 'replacement', 'Use the latest track callback');
    mediaSession.setActionHandler('nexttrack', null);
    assert.equal(state().nexttrack, false);
    assert.equal(await bridge.run('nexttrack'), false);
    assert.equal(await bridge.run('seekforward'), false, 'Do not expose arbitrary registered actions');

    await bridge.run('volumeup');
    assert.equal(volume, 55);
    assert(Math.abs(player.volume - 0.44) < 1e-10, "Preserve player loudness normalization");
    await bridge.run('volumedown');
    assert.equal(volume, 50);
    await bridge.run('mute');
    assert.equal(state().muted, true);
    assert.equal(volume, 50, 'Mute preserves volume');
    await bridge.run('mute');
    assert.equal(state().muted, false);
    volume = 98;
    await bridge.run('volumeup');
    assert.equal(volume, 100);
    assert.equal(state().volumeup, false);
    audio.mute();
    await bridge.run('volumeup');
    assert.equal(player.muted, false, 'Volume Up unmutes even at maximum volume');
    volume = 2;
    await bridge.run('volumedown');
    assert.equal(player.volume, 0);
    assert.equal(state().volumedown, false);

    document.activeElement = { matches: () => true, isContentEditable: false };
    document.dispatchEvent(new Event('focusin'));
    await Promise.resolve();
    assert.equal(state().editing, true);
    document.activeElement = { shadowRoot: { activeElement: { isContentEditable: true } } };
    document.dispatchEvent(new Event('focusin'));
    await Promise.resolve();
    assert.equal(state().editing, true, 'Protect editable fields in shadow DOM');
    document.activeElement = null;
    document.dispatchEvent(new Event('focusout'));
    await Promise.resolve();
    assert.equal(state().editing, false);
    player.paused = false;
    document.dispatchEvent(new Event('play'));
    await Promise.resolve();
    assert.equal(state().paused, false, 'Reflect playback changes made on the website');

    mediaSession.setActionHandler('pause', async () => { throw new Error('Playback failed'); });
    await assert.rejects(bridge.run('playpause'), /Playback failed/);
    assert.equal(state().paused, false, 'A failed command must not pretend playback changed');
    const controls = audio;
    audio = null;
    bridge.update();
    assert.equal(state().volumeup, false);
    assert.equal(state().mute, false);
    assert.equal(await bridge.run('volumeup'), false, 'Do not bypass the player if its volume API is absent');
    audio = { ...controls, unMute: undefined };
    bridge.update();
    assert.equal(state().mute, false, 'Disable an incomplete player API');
    audio = { ...controls, getVolume: () => NaN };
    assert.equal(await bridge.run('volumeup'), false, 'Do not write invalid volume values');
    audio = controls;
    controlsChanged([{ target: { closest: () => true }, addedNodes: [] }]);
    assert.equal(state().mute, true, 'Enable a late-mounted player API without another media event');
    player.error = {};
    document.dispatchEvent(new Event('error'));
    await Promise.resolve();
    assert.equal(state().playpause, false);
    assert.equal(state().mute, false);
    assert.equal(await bridge.run('mute'), false);
    elements = [];
    document.dispatchEvent(new Event('emptied'));
    await Promise.resolve();
    assert.equal(state().playpause, false);
    const count = messages.length;
    bridge.update();
    assert.equal(messages.length, count, 'Do not resend unchanged state');
    bridge.update(true);
    assert.equal(messages.length, count + 1, 'A navigation reset can request a fresh state');
    console.log('PASS: playback dispatch, state, volume bounds, mute, focus, origin isolation, and failures');
})().catch(error => { console.error(error); process.exitCode = 1; });
