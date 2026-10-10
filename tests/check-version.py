#!/usr/bin/env python3
"""Check source-based releases without Git, signing credentials, or network."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-version-check-") as directory:
    work = Path(directory)
    repo = work / "repo"
    for name in ("scripts", "Music", "Music.xcodeproj", "packaging", "tests", "docs", "updates"):
        (repo / name).mkdir(parents=True)
    shutil.copy(root / "scripts/release.sh", repo / "scripts/release.sh")
    shutil.copytree(root / "Music.xcodeproj", repo / "Music.xcodeproj", dirs_exist_ok=True)
    for name in ("README.md", "LICENSE", "THIRD_PARTY_NOTICES.txt", "Music/main.swift"):
        (repo / name).write_text("source fixture\n")
    for name in ("AGENTS.md", "release.md", ".env"):
        (repo / name).write_text("local-only fixture\n")
    (repo / "Music.xcodeproj/xcuserdata").mkdir(exist_ok=True)
    (repo / "Music.xcodeproj/xcuserdata/private.txt").write_text("local-only fixture")
    project = repo / "Music.xcodeproj/project.pbxproj"
    template = project.read_text()

    def version(value):
        import re
        project.write_text(re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {value};", template))

    def feed(marketing="1.1.2", build="52", arch="arm64"):
        (repo / f"updates/appcast-{arch}.xml").write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{marketing}</sparkle:shortVersionString></item></channel></rss>')

    def check(expected, tag="", rebuild=False):
        result = subprocess.run(["bash", "scripts/release.sh", "--version", tag, *(["--rebuild"] if rebuild else [])], cwd=repo, capture_output=True, text=True)
        if expected.startswith(("v", "music-")) and " " in expected and expected.split()[-1].isdigit():
            assert result.returncode == 0 and result.stdout.strip() == expected, result
        else:
            assert result.returncode != 0 and expected in result.stderr, result

    version("1.1.3")
    feed()
    feed(build="55", arch="x86_64")
    check("v1.1.3 1.1.3 56")
    check("v1.1.3 1.1.3 56", "v1.1.3")
    check("music-1.1.3 1.1.3 56", "music-1.1.3")
    for invalid in ("v01.1.3", "v1.1", "../1.1.3", "v1.1.3\n"):
        check("Expected a release version", invalid)
    check("must match MARKETING_VERSION", "v1.1.4")
    check("latest release version", "v1.1.3", rebuild=True)
    version("1.1.2")
    check("use --rebuild")
    check("v1.1.2 1.1.2 56", "v1.1.2", rebuild=True)
    version("1.1.1")
    check("Version must be newer")
    version("1.1.3")
    feed(build="invalid")
    check("Invalid build number")
    feed()
    receipt = repo / "dist/notarization/1.1.3-60"
    receipt.mkdir(parents=True)
    check("use --rebuild")
    check("v1.1.3 1.1.3 61", "v1.1.3", rebuild=True)
    version("1.1.4")
    check("v1.1.4 1.1.4 61")

    # Stop at the real archive entry point; signing/notarization must never run here.
    tools = work / "bin"
    tools.mkdir()
    xcodebuild = tools / "xcodebuild"
    xcodebuild.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 99\n')
    xcodebuild.chmod(0o755)
    sparkle = work / "Sparkle"
    resources = sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Resources"
    resources.mkdir(parents=True)
    (resources / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "2.10.0"}))
    (sparkle / "bin").mkdir()
    for name in ("generate_appcast", "sign_update"):
        (sparkle / "bin" / name).touch()
    result = subprocess.run(["bash", "scripts/release.sh"], cwd=repo, capture_output=True,
                            env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], MUSIC_SPARKLE_DIR=str(sparkle)))
    assert result.returncode == 99, result.stderr
    workspace = next((repo / "dist").glob("release.*"))
    log = (workspace / "build-arm64.log").read_text().splitlines()
    assert "MARKETING_VERSION=1.1.4" in log and "CURRENT_PROJECT_VERSION=61" in log, log
    assert "XCLocalSwiftPackageReference" in (workspace / "source/Music.xcodeproj/project.pbxproj").read_text()
    with tarfile.open(workspace / "source.tar.gz") as archive:
        names = archive.getnames()
        assert not any("xcuserdata" in name or name.endswith(("AGENTS.md", "release.md", ".env")) for name in names)
        for line in (workspace / "source-files.sha256").read_text().splitlines():
            expected, name = line.split("  ", 1)
            assert hashlib.sha256(archive.extractfile("source/" + name).read()).hexdigest() == expected
        assert archive.extractfile("source/Music/main.swift").read() == b"source fixture\n"
    assert project.read_text().count("XCRemoteSwiftPackageReference") > 0, "Only the snapshot uses a local dependency"
print("PASS: no-tag releases, increasing feed/receipt builds, rebuild validation, source snapshot, private-file exclusions, and archive arguments")
