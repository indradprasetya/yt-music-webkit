#!/usr/bin/env python3
"""Verify Finder saved the installer layout before sealing or shipping a DMG."""
from pathlib import Path
import struct
import sys

volume = Path(sys.argv[1])
data = (volume / ".DS_Store").read_bytes()
for name, position in [("Music.app", (160, 185)), ("Applications", (480, 185))]:
    marker = name.encode("utf-16be") + b"Ilocblob" + struct.pack(">I", 16)
    # ponytail: require one Iloc record; use a DS_Store parser if Finder retains stale records.
    assert data.count(marker) == 1, f"Missing or ambiguous Finder position for {name}"
    offset = data.index(marker) + len(marker)
    actual = struct.unpack_from(">II", data, offset)
    assert actual == position, f"Finder has not saved {name}: {actual}, expected {position}"
assert (volume / "Applications").readlink() == Path("/Applications")
assert (volume / ".background/background.png").is_file()
print(f"PASS: {volume.name}: Music → Applications layout saved")
