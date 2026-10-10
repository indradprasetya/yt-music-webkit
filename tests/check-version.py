#!/usr/bin/env python3
"""Run python3 tests/check-version.py; no signing credentials or network needed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="music-version-check-") as directory:
    work = Path(directory)
    repo = work / "repo"
    (repo / "scripts").mkdir(parents=True)
    shutil.copy(root / "scripts/release.sh", repo / "scripts/release.sh")
    (repo / ".gitignore").write_text("dist/\n")

    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

    def check(expected, tag="", cwd=repo, rebuild=False):
        result = subprocess.run(["bash", "scripts/release.sh", "--version", tag, *(["--rebuild"] if rebuild else [])],
                                cwd=cwd, capture_output=True, text=True)
        if expected.startswith(("music-", "v")) or expected[:1].isdigit():
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == expected, result.stdout
        else:
            assert result.returncode != 0 and expected in result.stderr, result

    git("init", "-q")
    git("config", "user.name", "Version Check")
    git("config", "user.email", "version-check@example.invalid")
    git("add", ".")
    git("commit", "-qm", "Initial")
    check("tag on HEAD")
    git("tag", "music-1.1.0")
    check("music-1.1.0 1.1.0 1")
    git("commit", "--allow-empty", "-qm", "Next release")
    check("tag on HEAD", "music-1.1.0")
    git("tag", "-a", "v1.1.1", "-m", "Music 1.1.1")
    check("v1.1.1 1.1.1 2")
    check("v1.1.1 1.1.1 2", "v1.1.1")
    check("tag on HEAD", "music-01.1.1")
    check("tag on HEAD", "01.1.1")
    check("tag on HEAD", "v01.1.1")
    git("tag", "1.1.1")
    check("tag on HEAD")
    check("1.1.1 1.1.1 2", "1.1.1")
    git("tag", "-d", "1.1.1")
    (repo / "pending.txt").write_text("not committed")
    check("Commit or stash")
    git("add", "pending.txt")
    check("Commit or stash")
    git("reset", "-q", "HEAD", "pending.txt")
    (repo / "pending.txt").unlink()
    git("tag", "v1.1.2")
    check("Build number must exceed", "v1.1.2")
    git("tag", "-d", "v1.1.2")

    # Exercise the actual release entrypoint, stopping before signing or notarization.
    tools = work / "bin"
    tools.mkdir()
    xcodebuild = tools / "xcodebuild"
    xcodebuild.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 99\n')
    xcodebuild.chmod(0o755)
    result = subprocess.run(["bash", "scripts/release.sh"], cwd=repo, capture_output=True,
                            env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"]))
    assert result.returncode == 99, result.stderr
    log = next((repo / "dist").glob("release.*/build-arm64.log")).read_text().splitlines()
    assert "MARKETING_VERSION=1.1.1" in log and "CURRENT_PROJECT_VERSION=2" in log, log

    check("newer commit", "v1.1.1", rebuild=True)
    check("explicit existing release tag", rebuild=True)
    git("commit", "--allow-empty", "-qm", "Rebuild current release")
    check("tag on HEAD", "v1.1.1")
    check("v1.1.1 1.1.1 3", "v1.1.1", rebuild=True)
    check("Release version must be newer", "music-1.1.0", rebuild=True)
    check("explicit existing release tag", "v9.9.9", rebuild=True)
    unrelated = git("commit-tree", "HEAD^{tree}", "-m", "Unrelated history")
    git("tag", "v2.0.0", unrelated)
    check("ancestor of HEAD", "v2.0.0", rebuild=True)
    git("tag", "-d", "v2.0.0")
    git("tag", "v1.1.2")
    (repo / "updates").mkdir()
    feed = repo / "updates/appcast-arm64.xml"
    feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>4</sparkle:version></item></channel></rss>')
    git("add", "updates")
    git("commit", "-qm", "Record release feed")
    check("Build number must exceed 4", "v1.1.2", rebuild=True)
    git("commit", "--allow-empty", "-qm", "Next build")
    check("v1.1.2 1.1.2 5", "v1.1.2", rebuild=True)

    shallow = work / "shallow"
    subprocess.run(["git", "clone", "-q", "--depth=1", repo.as_uri(), str(shallow)], check=True)
    check("Fetch full history", cwd=shallow)
    git("commit", "--allow-empty", "-qm", "Older version")
    git("tag", "1.0.9")
    check("Release version must be newer", "1.0.9")
    assert not (shallow / "dist").exists()
print("PASS: tagged releases, same-version rebuilds, ancestor/latest-tag checks, increasing feed builds, and archive build arguments")
