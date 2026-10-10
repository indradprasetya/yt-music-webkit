#!/usr/bin/env python3
"""Validate native icon variants with python3 tests/check-app-icon.py; no app build or theme changes."""
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
assets = root / "Music/Assets.xcassets"
source = (root / "Music/main.swift").read_text()
assert "applicationIconImage =" not in source, "Let macOS select icon style independently of app theme"
assert "iconAppearanceObservation" not in source
assert not list((root / "Music").glob("*.icon")), "No Icon Composer document required"
info = plistlib.loads((root / "Music/Info.plist").read_bytes())
assert info["CFBundleIconName"] == info["CFBundleIconFile"] == "AppIcon"
project = (root / "Music.xcodeproj/project.pbxproj").read_text()
assert project.count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;") == 2
layer = json.loads((assets / "AppIcon.iconstack/Artwork.iconstackgroup/Logo.iconstacklayer/Contents.json").read_text())
images = {entry["icon-studio-appearance"]: entry["value"]["name"] for entry in layer["properties"]["image"]}
assert images == {"unspecified": "Light", "light": "Light", "dark": "Dark", "tinted": "TintedLight"}
assert layer["properties"]["frame"][0]["value"] == {
    "origin.x": 0, "origin.y": 0, "size.width": 1024, "size.height": 1024,
}, "Full-canvas exports must not inherit the old icon's zoom/crop"
# shortcut: macOS icon stacks expose three appearances; map the other exports when actool supports them.
variants = {"Light", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"}
assert {path.stem for path in assets.glob("*.imageset")} == variants
for name in variants:
    folder = assets / f"{name}.imageset"
    manifest = json.loads((folder / "Contents.json").read_text())
    png = (folder / manifest["images"][0]["filename"]).read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", png[16:24]) == (1024, 1024), name

env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
with tempfile.TemporaryDirectory(prefix="music-icon-check-") as directory:
    work = Path(directory)
    # ICNS resources must contain the same artwork as the canonical PNG exports.
    for name, resource in [("Light", "icon.icns"), ("Dark", "icon-dark.icns")]:
        for kind, original in [("icns", root / "Music" / resource),
                               ("png", assets / f"{name}.imageset" / f"{name.lower()}.png")]:
            subprocess.run(["sips", "-s", "format", "bmp", "-s", "dpiWidth", "72", "-s", "dpiHeight", "72", str(original),
                            "--out", str(work / f"{kind}.bmp")], check=True, capture_output=True)
        assert (work / "icns.bmp").read_bytes() == (work / "png.bmp").read_bytes(), name
    result = subprocess.run([
        "xcrun", "actool", str(assets), "--compile", str(work), "--app-icon", "AppIcon",
        "--output-partial-info-plist", str(work / "Info.plist"), "--platform", "macosx",
        "--minimum-deployment-target", "12.0", "--warnings", "--errors", "--notices",
        "--output-format", "human-readable-text",
    ], env=env, check=True, capture_output=True, text=True, timeout=60)
    assert "warning:" not in result.stdout + result.stderr, result.stdout + result.stderr
    catalog = json.loads(subprocess.check_output(["/usr/bin/assetutil", "--info", str(work / "Assets.car")]))
    appearances = {entry.get("Appearance") for entry in catalog
                   if entry.get("AssetType") == "IconImageStack" and entry.get("Name") == "AppIcon"}
    assert appearances == {"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"}, appearances
    assert variants <= {entry.get("Name") for entry in catalog}, "All six exports must be bundled"
    compiled_info = plistlib.loads((work / "Info.plist").read_bytes())
    assert compiled_info["CFBundleIconName"] == compiled_info["CFBundleIconFile"] == "AppIcon"
print("PASS: six bundled exports, native default/dark/tintable icons, matching ICNS artwork, and no runtime icon override")
