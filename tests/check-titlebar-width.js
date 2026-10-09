// Run with: node tests/check-titlebar-width.js
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const source = readFileSync(join(__dirname, '../Music/main.swift'), 'utf8');
const script = [...source.matchAll(/WKUserScript\(source: """([\s\S]*?)""", injectionTime/g)][1][1];
let frame, resize, mutation, message;
const properties = new Map();
const watched = new Set();
const scroller = {
    offsetWidth: 1200, clientWidth: 1182, scrollHeight: 2000, clientHeight: 800, clientLeft: 0,
    getBoundingClientRect: () => ({ left: 0 }),
};
const context = {
    location: { hostname: 'music.youtube.com' }, innerWidth: 1200,
    document: {
        documentElement: { clientWidth: 1200, style: { setProperty: (key, value) => properties.set(key, value) } },
        elementsFromPoint: () => [scroller],
    },
    requestAnimationFrame: callback => { frame = callback; },
    ResizeObserver: class {
        constructor(callback) { resize = callback; }
        observe(element) { watched.add(element); }
        unobserve(element) { watched.delete(element); }
    },
    MutationObserver: class {
        constructor(callback) { mutation = callback; }
        observe() {}
    },
    window: {
        addEventListener() {},
        webkit: { messageHandlers: { titlebarContentWidth: { postMessage: value => { message = value; } } } },
    },
};
runInNewContext(script, context);
frame();
assert.equal(message.contentWidth, 1182, 'Exclude the nested scrollbar');
assert.equal(properties.get('--music-header-content-width'), '1182px', 'Keep header overlays off the scrollbar');
assert.equal(watched.size, 1);
message = null;
mutation([{ type: 'childList' }]);
frame();
assert.equal(message, null, 'Sidebar/content changes must not trigger color sampling');
scroller.clientWidth = 1200;
mutation([{ type: 'attributes', target: scroller }]);
frame();
assert.equal(message.contentWidth, 1200, 'Handle a scrollbar hidden without a resize event');
assert.equal(properties.get('--music-header-content-width'), '1200px', 'Restore the full header when the gutter disappears');
message = null;
mutation([{ type: 'attributes', target: {} }]);
frame();
assert.equal(message, null, 'Unrelated style changes must not send redundant updates');
context.document.elementsFromPoint = () => [];
resize();
frame();
assert.equal(watched.size, 0, 'Release observations of detached elements');
console.log('PASS: gutter measurement, redundant-update suppression, and observer cleanup');
