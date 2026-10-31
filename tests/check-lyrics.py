#!/usr/bin/env python3
"""Check native providers and their real WebKit bridge; --live TITLE ARTIST SECONDS uses real services."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-lyrics-check-") as directory:
    work = Path(directory)
    source = work / "main.swift"
    source.write_text((root / "tests/lyrics-fixture.swift").read_text())
    binary = work / "LyricsCheck"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
                    str(root / "Music/MusicLyricsProvider.swift"), str(root / "Music/MusicLyrics.swift"),
                    str(source), "-o", str(binary)], check=True,
                   env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
    variants = [sys.argv[1:]] if len(sys.argv) > 1 else [[], ["--english"], ["--media-session"]]
    for arguments in variants:
        subprocess.run([str(binary), *arguments], check=True, timeout=60)
