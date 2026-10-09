// Run with: node tests/check-download.js
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const html = readFileSync(join(__dirname, '../docs/download.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const repo = 'https://github.com/indradprasetya/yt-music-webkit';
const releases = `${repo}/releases/latest`;
const makeAsset = (label, version) => ({
    name: `Music-${version}-${label}.dmg`,
    browser_download_url: `${repo}/releases/download/v${version}/Music-${version}-${label}.dmg`,
});

async function run(search, fetch, timeout = false) {
    const nodes = { status: {}, download: { href: releases } };
    const redirects = [];
    let cleared = false;
    await runInNewContext(script, {
        URLSearchParams, AbortController, fetch,
        document: { getElementById: id => nodes[id] },
        location: { search, replace: url => redirects.push(url) },
        setTimeout(callback, ms) {
            assert.equal(ms, 10000);
            if (timeout) queueMicrotask(callback);
            return 1;
        },
        clearTimeout() { cleared = true; },
    });
    return { nodes, redirects, cleared };
}

(async () => {
    for (const version of ['1.1.1', '12.34.56']) {
        const assets = [makeAsset('Intel', version), makeAsset('Apple-Silicon', version)];
        for (const [arch, label] of [['arm64', 'Apple-Silicon'], ['x86_64', 'Intel']]) {
            const result = await run(`?arch=${arch}`, async (url, options) => {
                assert.equal(url, 'https://api.github.com/repos/indradprasetya/yt-music-webkit/releases/latest');
                assert.equal(options.cache, 'no-store');
                assert(options.signal instanceof AbortSignal);
                return { ok: true, json: async () => ({ assets }) };
            });
            const expected = makeAsset(label, version);
            assert.deepEqual(result.redirects, [expected.browser_download_url]);
            assert.equal(result.nodes.download.href, expected.browser_download_url);
            assert(result.nodes.status.textContent.includes(expected.name));
            assert(result.cleared);
        }
    }

    for (const search of ['', '?arch=unknown', '?arch=constructor', '?arch=__proto__']) {
        const result = await run(search, () => assert.fail('Invalid architecture must not fetch a release'));
        assert.deepEqual(result.redirects, [releases]);
    }

    const failures = [
        async () => { throw new Error('Offline'); },
        async () => ({ ok: false, status: 403 }),
        async () => ({ ok: false, status: 404 }),
        async () => ({ ok: true, json: async () => { throw new Error('Invalid JSON'); } }),
        ...[
            {}, { assets: [] }, { assets: [makeAsset('Intel', '1.1.1')] },
            { assets: [{ name: 'Music-1.1.1-Apple-Silicon.dmg', browser_download_url: 'https://example.com/installer.dmg' }] },
            { assets: [{ name: 'Music-1.1.1-Apple-Silicon.dmg', browser_download_url: `${repo}.evil.example/releases/download/file.dmg` }] },
        ].map(release => async () => ({ ok: true, json: async () => release })),
    ];
    for (const fetch of failures) {
        const result = await run('?arch=arm64', fetch);
        assert.deepEqual(result.redirects, [releases]);
        assert.equal(result.nodes.download.href, releases);
        assert(result.nodes.status.textContent.includes('GitHub Releases'));
        assert(result.cleared);
    }

    const timedOut = await run('?arch=arm64', (url, { signal }) => new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(new Error('Timeout')), { once: true });
    }), true);
    assert.deepEqual(timedOut.redirects, [releases]);
    assert(timedOut.cleared);
    assert(html.includes('<noscript>'));
    console.log('PASS: both architectures, changing versions, invalid links, API failures, unsafe URLs, and timeout fallback');
})().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
