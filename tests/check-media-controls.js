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
const install = (hostname, navigator) => runInNewContext(script, {
    location: { hostname }, navigator, MediaSession, document: new EventTarget(), setTimeout, clearTimeout,
});

const original = mediaSession.setActionHandler;
install('accounts.google.com', { mediaSession });
assert.equal(mediaSession.setActionHandler, original);
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
