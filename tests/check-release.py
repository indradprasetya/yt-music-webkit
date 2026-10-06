#!/usr/bin/env python3
"""Check a local release folder, or --published, followed by its GitHub tag."""
import hashlib
from pathlib import Path
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

if len(sys.argv) != 3:
    sys.exit("Usage: python3 tests/check-release.py <upload-folder|--published> <release-tag>")
source, tag = sys.argv[1:]
repo = "https://github.com/indradprasetya/yt-music-webkit"
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

def read(name):
    try:
        if source == "--published":
            with urllib.request.urlopen(f"{repo}/releases/latest/download/{name}", timeout=30) as response:
                return response.read()
        return (Path(source) / name).read_bytes()
    except (OSError, urllib.error.URLError) as error:
        sys.exit(f"Cannot read {name}: {error}. Upload all five files to the latest release.")

checksums = dict(line.split(maxsplit=1)[::-1] for line in read("SHA256SUMS.txt").decode().splitlines())
for arch, label in [("arm64", "Apple-Silicon"), ("x86_64", "Intel")]:
    feed_name = f"appcast-{arch}.xml"
    feed_data = read(feed_name)
    item = ET.fromstring(feed_data).find("./channel/item")
    assert item is not None, f"Missing update in {feed_name}"
    version = item.findtext(f"{{{namespace}}}shortVersionString")
    filename = f"Music-{version}-{label}.dmg"
    enclosure = item.find("enclosure")
    assert enclosure is not None and enclosure.get("url") == f"{repo}/releases/download/{tag}/{filename}", f"Wrong release tag or package in {feed_name}"
    assert enclosure.get(f"{{{namespace}}}edSignature"), f"Missing signature in {feed_name}"
    archive = read(filename)
    assert len(archive) == int(enclosure.get("length")), f"Wrong size for {filename}"
    for name, data in [(feed_name, feed_data), (filename, archive)]:
        assert hashlib.sha256(data).hexdigest() == checksums.get("./" + name), f"Checksum mismatch: {name}"
    print(f"PASS: {tag} / {label}: feed, download URL, archive size, and checksums")
