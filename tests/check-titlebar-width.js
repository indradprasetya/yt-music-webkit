// Run with: node tests/check-titlebar-width.js
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const source = readFileSync(join(__dirname, '../Music/main.swift'), 'utf8');
const script = [...source.matchAll(/WKUserScript\(source: """([\s\S]*?)""", injectionTime/g)][1][1];
let frame, resize, mutation, message;
const watched = new Set();
const scroller = {
    offsetWidth: 1200, clientWidth: 1182, scrollHeight: 2000, clientHeight: 800, clientLeft: 0,
    getBoundingClientRect: () => ({ left: 0 }),
};
const context = {
    location: { hostname: 'music.youtube.com' }, innerWidth: 1200,
    document: { documentElement: { clientWidth: 1200 }, elementsFromPoint: () => [scroller] },
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
assert.equal(watched.size, 1);
message = null;
mutation();
frame();
assert.equal(message, null, 'Sidebar/content changes must not trigger color sampling');
scroller.clientWidth = 1200;
resize();
frame();
assert.equal(message.contentWidth, 1200, 'Handle a disappearing scrollbar');
context.document.elementsFromPoint = () => [];
mutation();
frame();
assert.equal(watched.size, 0, 'Release observations of detached elements');
console.log('PASS: gutter measurement, redundant-update suppression, and observer cleanup');
