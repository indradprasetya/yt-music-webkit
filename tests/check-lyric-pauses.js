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
const indicator = {dataset: {start: '12000', end: '25000'}, hidden: true,
    querySelectorAll: () => dots};
const motion = {matches: false};
const update = new Function('overlay', 'reducedMotion', 'time', 'holdLayout', updateBody[1])
    .bind(null, {querySelectorAll: () => [indicator]}, motion);
assert.equal(update(11000), null);
assert.equal(indicator.hidden, true);
assert.equal(update(15000), indicator);
assert.equal(indicator.hidden, false);
assert.equal(dots[0].style.opacity, '0.3');
update(23500);
assert.equal(dots[0].style.opacity, '1');
assert.ok(Number(dots[1].style.opacity) > .3);
assert.equal(dots[2].style.opacity, '0.3');
const frozen = JSON.stringify(dots);
update(23500);
assert.equal(JSON.stringify(dots), frozen, 'Animation depends on media time, not wall time');
motion.matches = true;
update(24000);
assert.ok(dots.every(dot => dot.style.transform === 'scale(1)'));
assert.equal(update(25000), null);
assert.equal(indicator.hidden, true);
assert.equal(update(15000), indicator, 'Seeking backwards restores the pause');
console.log('PASS: countdown progress, boundaries, frozen playback, reduced motion and backwards seeks');

update(25000);
assert.equal(update(15000, true), indicator, 'Keep logical pause detection while sync controls hold layout');
assert.equal(indicator.hidden, true, 'An instrumental boundary must not insert a block and shift sync targets');
update(15000);
assert.equal(indicator.hidden, false, 'Restore pause visibility when sync interaction ends');
assert.equal(update(25000, true), null);
assert.equal(indicator.hidden, false, 'Removing a pause block must also wait until sync interaction ends');
update(25000);
assert.equal(indicator.hidden, true);
console.log('PASS: instrumental boundaries preserve sync targets until following resumes');
