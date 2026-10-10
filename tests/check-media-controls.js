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
let queue = null;
let shuffleButton = null;
let repeatButton = null;
document.querySelector = selector => {
    if (selector === 'ytmusic-app') return { getState: () => ({queue}) };
    assert.equal(selector, '#movie_player', 'Volume controls must not depend on the old player-bar layout');
    return audio;
};
document.querySelectorAll = selector => {
    if (selector === 'video, audio') return elements;
    if (selector.includes('ShuffleButton')) return shuffleButton ? [shuffleButton] : [];
    assert(selector.includes('RepeatButton'));
    return repeatButton ? [repeatButton] : [];
};
document.activeElement = null;
const messages = [];
let controlsChanged;
let observedAttributes;
const window = { webkit: { messageHandlers: { playbackState: { postMessage: state => messages.push(state) } } } };
const install = (hostname, navigator, protocol = 'https:') => runInNewContext(script, {
    location: { hostname, protocol }, navigator, MediaSession, document, window, queueMicrotask, Event, setTimeout,
    MutationObserver: class {
        constructor(callback) { controlsChanged = callback; }
        observe(target, options) { observedAttributes = options.attributeFilter; }
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
    controlsChanged([{ target: { closest: () => true }, addedNodes: [], removedNodes: [] }]);
    assert.equal(state().mute, true, 'Enable a late-mounted player API without another media event');

    assert.equal(state().shuffle, false);
    assert.equal(state().repeatall, false);
    assert.equal(await bridge.run('repeatone'), false, 'Missing queue state cannot enable repeat');
    queue = {shuffleEnabled: false, repeatMode: 'NONE'};
    const button = click => ({
        disabled: false, hidden: false, blocked: false,
        closest() { return this.blocked; },
        getClientRects() { return this.hidden ? [] : [{}]; },
        click,
    });
    let repeatClicks = 0;
    const cycleRepeat = () => {
        repeatClicks++;
        const modes = ['NONE', 'ALL', 'ONE'];
        queue.repeatMode = modes[(modes.indexOf(queue.repeatMode) + 1) % modes.length];
        repeatButton = button(cycleRepeat); // YouTube may replace the button after a click.
    };
    shuffleButton = button(() => { queue.shuffleEnabled = !queue.shuffleEnabled; });
    repeatButton = button(cycleRepeat);
    const webChanged = () => controlsChanged([{target: {closest: () => true}, addedNodes: [], removedNodes: []}]);
    for (const attr of ['aria-pressed', 'aria-label', 'aria-disabled', 'disabled', 'hidden']) {
        assert(observedAttributes.includes(attr), `Observe website changes to ${attr}`);
    }
    webChanged();
    assert.equal(state().shuffle, true);
    assert.equal(state().repeatoffSelected, true);
    assert.equal(await bridge.run('shuffle'), true);
    assert.equal(state().shuffled, true);
    assert.equal(await bridge.run('shuffle'), true);
    assert.equal(state().shuffled, false);
    for (const start of ['NONE', 'ALL', 'ONE']) {
        for (const [action, wanted] of Object.entries({repeatoff: 'NONE', repeatall: 'ALL', repeatone: 'ONE'})) {
            queue.repeatMode = start;
            repeatClicks = 0;
            assert.equal(await bridge.run(action), true);
            assert.equal(queue.repeatMode, wanted, `${start} -> ${wanted}`);
            assert.equal(state()[action + 'Selected'], true);
            assert.equal(['repeatoff', 'repeatall', 'repeatone'].filter(a => state()[a + 'Selected']).length, 1);
            assert(start === wanted ? repeatClicks === 0 : repeatClicks <= 2, 'Never toggle an already-selected mode');
        }
    }
    queue.shuffleEnabled = true;
    queue.repeatMode = 'ALL';
    webChanged();
    assert.equal(state().shuffled, true, 'Reflect changes made on the website');
    assert.equal(state().repeatallSelected, true);
    const pending = bridge.run('repeatoff');
    assert.equal(state().repeatone, false, 'Disable queue commands while cycling');
    assert.equal(await bridge.run('repeatone'), false, 'Do not interleave repeat cycles');
    assert.equal(await pending, true);
    assert.equal(state().repeatone, true);
    for (const property of ['disabled', 'hidden', 'blocked']) {
        shuffleButton[property] = true;
        repeatButton[property] = true;
        webChanged();
        assert.equal(state().shuffle, false);
        assert.equal(state().repeatall, false);
        assert.equal(await bridge.run('shuffle'), false);
        assert.equal(await bridge.run('repeatone'), false);
        shuffleButton[property] = false;
        repeatButton[property] = false;
    }
    repeatButton.click = () => { repeatClicks++; };
    repeatClicks = 0;
    assert.equal(await bridge.run('repeatone'), false, 'Do not claim success when the website ignores a click');
    assert.equal(repeatClicks, 1, 'Stop when the website does not advance');
    shuffleButton.click = () => { throw new Error('Queue failed'); };
    await assert.rejects(bridge.run('shuffle'), /Queue failed/);
    assert.equal(state().shuffle, true, 'A failed command must release the busy state');
    queue.repeatMode = 'DISABLED';
    webChanged();
    assert.equal(state().repeatoff, false);
    assert.equal(state().repeatallSelected, false);
    assert.equal(await bridge.run('repeatoff'), false);
    assert.equal(await bridge.run('repeatinvalid'), false);
    shuffleButton = repeatButton = null;
    controlsChanged([{target: {}, addedNodes: [], removedNodes: [{matches: () => true}]}]);
    assert.equal(state().shuffle, false, 'Disable controls removed by navigation');
    assert.equal(state().repeatall, false);
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
    console.log('PASS: playback, volume, shuffle, repeat modes, website sync, disabled controls, focus, origin isolation, and failures');
})().catch(error => { console.error(error); process.exitCode = 1; });
