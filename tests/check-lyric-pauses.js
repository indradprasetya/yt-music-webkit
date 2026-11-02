// Exercise the gap calculation used by the injected WebKit renderer.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const source = fs.readFileSync(`${__dirname}/../Music/MusicLyrics.swift`, 'utf8');
const body = source.match(/function lyricPauses\(lines\) \{([\s\S]*?)\n            \}\n/);
assert.ok(body, 'The lyric renderer must calculate trustworthy pause intervals');
const pauses = new Function('lines', body[1]);
const line = (time, endTime) => ({time, endTime});
assert.deepEqual(pauses([line(10000, 12000), line(25000, 28000), line(30000, 32000)]), [
    {index: 0, start: 0, end: 10000}, {index: 1, start: 12000, end: 25000}
]);
assert.deepEqual(pauses([line(1000), line(20000)]), [], 'Do not guess LRC endings');
assert.deepEqual(pauses([line(10000), line(20000)]), [{index: 0, start: 0, end: 10000}]);
assert.deepEqual(pauses([{time: null}, {time: null}]), []);
assert.deepEqual(pauses([{time: 0, credit: true}, line(10000, 15000)]), [{index: 1, start: 0, end: 10000}]);
assert.deepEqual(pauses([line(0, 25000), line(10000, 12000), line(20000, 28000)]), [], 'Overlapping vocals are not gaps');
assert.deepEqual(pauses([line(0, 1000), line(6000, 7000)]), [{index: 1, start: 1000, end: 6000}]);
assert.deepEqual(pauses([line(0, 0), line(10000, 11000)]), [], 'Missing end must not become a pause');
console.log('PASS: trustworthy lyric pauses, intro, overlaps, credits, plain lyrics and thresholds');

const updateBody = source.match(/function updatePause\([^)]*\) \{([\s\S]*?)\n            \}\n/);
assert.ok(updateBody);
const dots = Array.from({length: 3}, () => ({style: {}}));
const classes = new Set();
const indicator = {dataset: {start: '12000', end: '25000'},
    classList: {toggle(name, on) { on ? classes.add(name) : classes.delete(name); }},
    style: {}, setAttribute() {}, querySelectorAll: () => dots};
const motion = {matches: false};
const update = new Function('overlay', 'reducedMotion', 'time', 'holdLayout', updateBody[1])
    .bind(null, {querySelectorAll: () => [indicator]}, motion);
assert.equal(update(11000), null);
assert.equal(classes.has('is-visible'), false);
assert.equal(update(15000), indicator);
assert.equal(classes.has('is-visible'), true);
assert.equal(dots[0].style.opacity, '0.3');
update(23500);
assert.equal(dots[0].style.opacity, '1');
assert.ok(Number(dots[1].style.opacity) > .3);
assert.equal(dots[2].style.opacity, '0.3');
assert.ok(dots.every(dot => Math.abs(Number(dot.style.transform.slice(6, -1)) - 1) <= .060000001), 'Keep pulse amplitude gentle');
const scale = Number(dots[0].style.transform.slice(6, -1));
assert.ok(Math.abs(scale - 1) > .04, 'Pulse should remain noticeable');
update(23600);
assert.ok(Math.abs(Number(dots[0].style.transform.slice(6, -1)) - scale) < .02, 'Keep pulse slow');
update(23500);
const frozen = JSON.stringify(dots);
update(23500);
assert.equal(JSON.stringify(dots), frozen, 'Countdown follows media time');
assert.equal(update(25000), null);
assert.equal(classes.has('is-visible'), true, 'Keep the spacer stable while dots fade');
assert.equal(indicator.style.opacity, '1');
update(25325);
assert.equal(classes.has('is-visible'), true);
assert.equal(indicator.style.opacity, '0.5', 'Fade gradually after the vocal starts');
const fadePaused = indicator.style.opacity;
update(25325);
assert.equal(indicator.style.opacity, fadePaused, 'Paused playback freezes the fade');
update(25650);
assert.equal(classes.has('is-visible'), false, 'Remove the spacer only after dots are transparent');
assert.equal(indicator.style.opacity, '0');
assert.equal(indicator.dataset.active, 'false');
assert.equal(update(15000, true), indicator);
assert.equal(classes.has('is-visible'), false, 'Hold layout during sync interaction');
update(15000);
assert.equal(classes.has('is-visible'), true, 'Backwards seek restores dots');
update(30000, true);
assert.equal(classes.has('is-visible'), true, 'Defer collapse during sync interaction');
update(30000);
assert.equal(classes.has('is-visible'), false);
motion.matches = true;
update(15000);
assert.ok(dots.every(dot => dot.style.transform === 'scale(1)'), 'Respect Reduced Motion');
console.log('PASS: gentle pulse, countdown, gradual fade with stable spacing, backwards seeks and sync layout');
