#!/usr/bin/env python3
"""Validate the published startup rules and pages; no Git or network needed."""
import json
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import urlsplit

root = Path(__file__).resolve().parents[1]
content = root / "docs/messages"
manifest = json.loads((content / "manifest.json").read_text())
assert manifest["schemaVersion"] == 1
assert isinstance(manifest["rules"], list)


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.images = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        assert tag not in {"script", "iframe", "form"}, f"Unsupported element: {tag}"
        if tag == "a":
            href = attrs.get("href", "")
            assert href in {"music-action://continue", "music-action://update"} or href.startswith("https://"), href
            self.links.append(href)
        if tag == "img":
            assert attrs.get("alt"), "Images need alternative text"
            self.images.append(attrs["src"])


for rule in manifest["rules"]:
    assert type(rule["enabled"]) is bool
    if "launches" in rule:
        assert isinstance(rule["launches"], list)
        assert all(value in {"firstLaunch", "versionChanged", "regular"} for value in rule["launches"])
    if "versions" in rule:
        assert isinstance(rule["versions"], list)
        assert all(isinstance(value, str) and value for value in rule["versions"])
    assert re.fullmatch(r"[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.html", rule["page"])
    path = content / rule["page"]
    page = Page()
    page.feed(path.read_text())
    assert "music-action://continue" in page.links, f"{path.name}: missing Continue"
    for src in page.images:
        url = urlsplit(src)
        assert not url.scheme and not url.netloc, "Host images alongside the page"
        image = (path.parent / src).resolve()
        assert image.is_relative_to(content.resolve()) and image.is_file(), src

welcome = Page()
welcome.feed((content / "welcome.html").read_text())
assert "https://ko-fi.com/indradprasetya" in welcome.links
assert "https://github.com/indradprasetya/yt-music-webkit/blob/main/README.md" in welcome.links
assert not list((root / "Music").rglob("*.html")), "Startup HTML must not be bundled"
assert not list((root / "Music").rglob("channels4_profile.jpg")), "Profile must not be bundled"
print("PASS: startup manifest, hosted pages, Continue/support/README links, and remote-only assets")
