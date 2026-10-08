#!/usr/bin/env python3
"""Validate native icon variants with python3 tests/check-app-icon.py; no app build or theme changes."""
import json
import os
from pathlib import Path
import plistlib
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
assert images == {"unspecified": "Light", "light": "Light", "dark": "Dark", "tinted": "Dark"}
assert {path.name for path in assets.glob("*.imageset")} == {"Light.imageset", "Dark.imageset"}

env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
with tempfile.TemporaryDirectory(prefix="music-icon-check-") as directory:
    work = Path(directory)
    # Format conversion only: both bitmaps must still come directly from the supplied ICNS files.
    for name, resource in [("Light", "icon.icns"), ("Dark", "icon-dark.icns")]:
        png = work / f"{name.lower()}.png"
        subprocess.run(["sips", "-s", "format", "png", str(root / "Music" / resource),
                        "--out", str(png)], check=True, capture_output=True)
        assert png.read_bytes() == (assets / f"{name}.imageset" / png.name).read_bytes()
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
    compiled_info = plistlib.loads((work / "Info.plist").read_bytes())
    assert compiled_info["CFBundleIconName"] == compiled_info["CFBundleIconFile"] == "AppIcon"
print("PASS: native default/dark/tintable variants, original artwork, and no runtime icon override")
