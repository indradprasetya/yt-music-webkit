// Run with: node tests/check-download.js
const assert = require('node:assert/strict');
const { readFileSync, writeFileSync, mkdtempSync, rmSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { spawnSync } = require('node:child_process');
const { runInNewContext } = require('node:vm');

const html = readFileSync(join(__dirname, '../docs/download.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const repo = 'https://github.com/indradprasetya/yt-music-webkit';
const releases = `${repo}/releases/latest`;
const makeAsset = (label, version) => ({
    name: `Music-${version}-${label}.dmg`,
    browser_download_url: `${repo}/releases/download/v${version}/Music-${version}-${label}.dmg`,
});

const readme = readFileSync(join(__dirname, '../README.md'), 'utf8');
const labels = ['Apple-Silicon', 'Intel'];
const links = ['arm64', 'x86_64'].map(arch => {
    const feed = readFileSync(join(__dirname, `../updates/appcast-${arch}.xml`), 'utf8');
    const url = feed.match(/<enclosure url="([^"]+)"/)[1];
    assert(readme.includes(`](${url})`), `README must link directly to the ${arch} installer`);
    return url;
});
const releaseScript = readFileSync(join(__dirname, '../scripts/release.sh'), 'utf8');
const updateLinks = releaseScript.match(/python3 - "\$repo" "\$release_tag" "\$version" <<'PY'\n([\s\S]*?)\nPY/)[1];
const work = mkdtempSync(join(tmpdir(), 'music-download-check-'));
try {
    const path = join(work, 'README.md');
    for (const tag of ['v12.34.56', 'music-12.34.56']) {
        writeFileSync(path, readme);
        const result = spawnSync('python3', ['-', repo, tag, '12.34.56'], { input: updateLinks, cwd: work, encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
        const expected = links.reduce((text, url, i) => text.replace(url,
            `${repo}/releases/download/${tag}/Music-12.34.56-${labels[i]}.dmg`), readme);
        assert.equal(readFileSync(path, 'utf8'), expected, 'A release only changes the two installer URLs');
    }
    const missingLink = readme.replace(links[1], releases);
    writeFileSync(path, missingLink);
    const result = spawnSync('python3', ['-', repo, 'v2.0.0', '2.0.0'], { input: updateLinks, cwd: work, encoding: 'utf8' });
    assert.notEqual(result.status, 0, 'Missing download links must fail visibly');
    assert.equal(readFileSync(path, 'utf8'), missingLink, 'Do not partially update the README');
} finally {
    rmSync(work, { recursive: true, force: true });
}
console.log('PASS: direct README downloads and automatic release-link updates');

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
