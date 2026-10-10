// Run with: node tests/check-scrollbar.js
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const source = readFileSync(join(__dirname, '../Music/main.swift'), 'utf8');
const script = [...source.matchAll(/WKUserScript\(source: """([\s\S]*?)""", injectionTime/g)]
    .map(match => match[1]).find(script => script.includes("bar.id = 'music-scrollbar'"));

function element() {
    return {
        style: {}, children: [], listeners: {}, scrollTop: 0, scrollHeight: 2000,
        get clientHeight() { return this.style.height ? parseFloat(this.style.height) : 800; },
        append(child) { this.children.push(child); },
        appendChild(child) { this.append(child); return child; },
        setAttribute(name, value) { this[name] = value; },
        addEventListener(name, callback) { this.listeners[name] = callback; },
        removeEventListener(name) { delete this.listeners[name]; },
        contains(target) { return target === this || this.children.includes(target); },
        getBoundingClientRect() { return { top: 0, right: 1200, bottom: 800, height: 800 }; },
    };
}

let frame, mutation, nested = element(), inset = 32, ready = 0;
const root = element(), body = element(), events = {};
const document = {
    documentElement: root, scrollingElement: root, body,
    createElement: element,
    querySelector: () => nested,
    addEventListener: (name, callback) => { events[name] = callback; },
    removeEventListener: name => { delete events[name]; },
};
runInNewContext(script, {
    location: { hostname: 'music.youtube.com' }, document,
    innerWidth: 1200, innerHeight: 800,
    requestAnimationFrame: callback => { frame = callback; },
    getComputedStyle: () => ({ visibility: 'visible', getPropertyValue: () => `${inset}px` }),
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    MutationObserver: class { constructor(callback) { mutation = callback; } observe() {} },
    window: {
        addEventListener() {},
        webkit: { messageHandlers: { titlebarReady: { postMessage() { ready++; } } } },
    },
});
const bar = body.children[0];
frame();
assert.equal(ready, 1, 'Request the current native inset after each page load');
assert.equal(bar.style.top, '40px', 'Start the thumb below the title bar');
assert.equal(bar.style.left, '1182px');
assert.equal(bar.children[0].style.height, '1952px', 'Keep the page and thumb scroll ranges equal');
nested.scrollTop = 192;
nested.listeners.scroll(); frame();
assert.equal(bar.scrollTop, 192);
bar.scrollTop = 320;
bar.listeners.scroll();
assert.equal(nested.scrollTop, 320, 'Dragging the thumb scrolls the nested page');

const detached = nested;
nested = null;
mutation([{ target: root }]); frame();
assert.equal(detached.listeners.scroll, undefined, 'Remove the old page listener');
assert.equal(bar.scrollTop, 0, 'Switch to the document without carrying over the old scroll position');
root.scrollTop = 96;
events.scroll(); frame();
assert.equal(bar.scrollTop, 96);
bar.scrollTop = 240;
bar.listeners.scroll();
assert.equal(root.scrollTop, 240, 'Dragging the thumb also scrolls the document');
assert.equal(detached.scrollTop, 320);

inset = 0;
mutation([{ target: root }]); frame();
assert.equal(bar.style.top, '8px', 'Remove the title-bar inset in full screen');
root.scrollHeight = 800;
mutation([{ target: root }]); frame();
assert.equal(bar.hidden, true, 'Hide the thumb when there is nothing to scroll');
console.log('PASS: title-bar inset, nested/document scrolling, replacement, full screen, and fitting content');
