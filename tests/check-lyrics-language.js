// Run the injected selection and bridge code without opening or focusing an app.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const source = fs.readFileSync(__dirname + '/../Music/MusicLyrics.swift', 'utf8');
function extract(name) {
    const match = source.match(new RegExp('            (?:async )?function ' + name + '\\([^\\n]*\\) \\{[\\s\\S]*?\\n            \\}'));
    assert.ok(match, name);
    return match[0].replaceAll('\\\\', '\\');
}
const functions = ['parseLRC', 'parseYRC', 'readLyrics', 'automaticLyrics', 'fetchLyrics'].map(extract).join('\n');
const creditPattern = source.match(/const creditPattern = .*?;/)[0].replaceAll('\\\\', '\\');
function renderer(reply) {
    let requests = 0;
    const window = {webkit: {messageHandlers: {musicLyricsLookup: {postMessage: async () => {
        requests++;
        return reply;
    }}}}};
    const api = new Function('window', [
        "const cache = new Map(), lifetime = {signal: {aborted: false}}, trackKey = 'song';",
        'let retryAfter = 0;', creditPattern, functions,
        'return {automaticLyrics, fetchLyrics, readLyrics};'
    ].join('\n'))(window);
    return {...api, requests: () => requests};
}
const {automaticLyrics: choose} = renderer();
const english = [
    'When the morning comes I will be waiting for you',
    'Every little star reminds me of the way back home',
    'Take my hand and we can find another place to go'
];
const chinese = [
    '当清晨的第一缕阳光照进窗户我仍然在这里等待着你回来',
    '夜空中每一颗明亮的星星都会让我想起那条熟悉的回家路',
    '请你握住我的手让我们一起去寻找一个可以安心停留的地方'
];
const lines = (texts, words = false) => texts.map((text, index) => ({
    text, time: (index + 1) * 10000,
    words: words ? [{word: text, start_time: (index + 1) * 10000, end_time: (index + 1) * 10000 + 3000}] : []
}));
const netEase = {source: 'NetEase', lines: lines(chinese, true)};
const latin = {source: 'LRCLIB', lines: lines(english)};
const result = (...alternatives) => ({...netEase, alternatives: [netEase, ...alternatives]});
const baseline = result(latin);
assert.equal(choose(baseline, []), baseline, 'One Latin provider is insufficient');
const selected = choose(baseline, lines(english));
assert.equal(selected.source, 'NetEase');
assert.deepEqual(selected.lines, lines(english), 'Prefer corroborated NetEase line lyrics over its Han words');
const better = {source: 'Better Lyrics', lines: lines(english, true)};
assert.equal(choose(result(latin, better), []), better, 'Two other providers can corroborate Latin word lyrics');
assert.deepEqual(choose(result(latin), lines(english.map(text => text.toUpperCase() + '!'))).lines,
    lines(english.map(text => text.toUpperCase() + '!')),
    'Ignore punctuation and letter case');
const unrelated = result(latin);
assert.equal(choose(unrelated, lines(english.map((_, i) => 'Completely different vocals about another distant memory ' + 'x'.repeat(i + 1)))),
    unrelated, 'Latin script without matching text is insufficient');
for (const texts of [
    chinese.map(text => text + 'かな'),
    chinese.map(text => text + '한글'),
    chinese.map(text => text + ' I will always remember you'),
    english,
    ['你好', '世界', '再见']
]) {
    const current = {...result(latin, better), lines: lines(texts, true)};
    assert.equal(choose(current, lines(english)), current, 'Keep Japanese, Korean, mixed, Latin and short lyrics');
}
const short = result({source: 'LRCLIB', lines: lines(['hello', 'world', 'again'])});
assert.equal(choose(short, lines(['hello', 'world', 'again'])), short);
const repeated = result({source: 'LRCLIB', lines: lines(Array(10).fill(english[0]))});
assert.equal(choose(repeated, lines(Array(10).fill(english[0]))), repeated, 'Repeated chorus is not three distinct lines');
assert.equal(choose(baseline, lines([...english, ...english.map(text => 'Another verse begins with ' + text)])), baseline,
    'Three shared lines must also cover most of both candidates');
const hanOnly = result({source: 'LRCLIB', lines: lines(chinese)});
assert.equal(choose(hanOnly, lines(chinese)), hanOnly, 'Keep Mandarin when providers agree on Han lyrics');
const credits = result({source: 'LRCLIB', lines: lines(english).map(line => ({...line, credit: true}))});
assert.equal(choose(credits, lines(english)), credits, 'Credits do not corroborate vocals');
const plain = result({...latin, lines: lines(english).map(line => ({...line, time: null}))});
assert.equal(choose(plain, lines(english)), plain, 'Untimed lyrics cannot replace synchronized lyrics');
const lineOnly = {...result(latin, better), lines: lines(chinese)};
assert.equal(choose(lineOnly, []), lineOnly, 'Keep scope to NetEase word lyrics');
const otherSource = {...result(latin, better), source: 'AMLL'};
assert.equal(choose(otherSource, []), otherSource);

async function checkBridge() {
    const syncedLyrics = english.map((text, index) => '[00:' + (index + 1) * 10 + ']' + text).join('\n');
    const yrcLyrics = chinese.map((text, index) => {
        const start = (index + 1) * 10000;
        return '[' + start + ',3000](' + start + ',3000,0)' + text;
    }).join('\n');
    const record = {source: 'NetEase', synchronized: true, syncedLyrics, yrcLyrics, plainLyrics: ''};
    const alternative = {source: 'LRCLIB', synchronized: true, syncedLyrics, plainLyrics: ''};
    const api = renderer({status: 'found', record, alternatives: [record, alternative]});
    const track = {artists: ['Artist']};
    const actual = await api.fetchLyrics(track, 'song');
    assert.deepEqual(actual.lines.map(line => line.text), english, 'Real parsing and bridge select the Latin LRC');
    assert.ok(actual.lines.every(line => !line.words.length));
    const manual = actual.alternatives.find(item => item.source === 'NetEase');
    assert.deepEqual(manual.lines.map(line => line.text), chinese, 'Manual NetEase keeps the original word lyrics');
    assert.ok(manual.lines.every(line => line.words.length));
    assert.equal(await api.fetchLyrics(track, 'song'), actual, 'Cache preserves the automatic choice');
    assert.equal(api.requests(), 1, 'No extra provider requests');
    console.log('PASS: conservative Latin/Han selection, mixed scripts, corroboration, real parsers, manual alternatives and cache');
}
checkBridge().catch(error => { console.error(error); process.exitCode = 1; });
