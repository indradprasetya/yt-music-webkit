#!/usr/bin/env python3
"""Check native providers and their real WebKit bridge; --live TITLE ARTIST SECONDS uses real services."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-lyrics-check-") as directory:
    work = Path(directory)
    source = work / "Sources" / "LyricsCheck"
    source.mkdir(parents=True)
    for path in (root / "Music/MusicLyricsProvider.swift", root / "Music/MusicLyrics.swift",
                 root / "Music/MusicTTML.swift"):
        shutil.copy2(path, source / path.name)
    shutil.copy2(root / "tests/lyrics-fixture.swift", source / "main.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LyricsCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "5.4.0")],
    targets: [.executableTarget(name: "LyricsCheck", dependencies: [.product(name: "Yams", package: "Yams")])],
    swiftLanguageVersions: [.v5]
)
''')
    variants = [sys.argv[1:]] if len(sys.argv) > 1 else [
        ["--providers-only"], ["--metadata-only"], ["--amll-only"], ["--five-sources-only"],
        ["--five-ui-only"], ["--provider-choice-only"], ["--align-ui-only"], ["--timing-input-only"], ["--blank-lines-only"],
        ["--source-offsets-only"], ["--mode-offsets-only"], ["--plain-ui-only"], ["--feedback-ui-only"],
        [], ["--english"], ["--media-session"]]
    for arguments in variants:
        subprocess.run(["xcrun", "swift", "run", "--package-path", str(work), "LyricsCheck", *arguments],
                       check=True, timeout=180,
                       env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
