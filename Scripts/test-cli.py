#!/usr/bin/env python3
"""Exercise the shipped CLI against an isolated real Harbor app and HTTP fixtures.

No user downloads, settings, or agent skills are used. --keep leaves the test app
open for a manual Settings check and prints its temporary paths.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent

def wait_for(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.15)
    raise AssertionError("Timed out waiting for observable state")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=ROOT / "build/HarborDerivedData/Build/Products/Debug/Harbor.app")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="harbor-cli-e2e-", dir="/tmp"))
    for folder in ["downloads", "torrents", "watch", "support", "home/.claude", "home/.copilot", "home/.gemini"]:
        (root / folder).mkdir(parents=True)
    suite = "co.hapy.harbor.ui-tests.cli." + uuid.uuid4().hex
    env = dict(os.environ, HARBOR_CLI_DIRECTORY=str(root / "ipc"), HARBOR_AGENT_HOME=str(root / "home"))
    cli = args.app / "Contents/Helpers/harbor"
    app_log = (root / "app.log").open("w")
    server_log = (root / "server.log").open("w")
    fixture = subprocess.Popen([sys.executable, str(ROOT / "Scripts/harbor-fixture-server.py"),
        "--ready-file", str(root / "ready.json"), "--log-file", str(root / "requests.jsonl"),
        "--work-directory", str(root / "fixtures"), "--ffmpeg", str(ROOT / "Vendor/MediaRuntime/arm64/bin/ffmpeg")], stdout=server_log, stderr=server_log)
    app = None
    def launch():
        return subprocess.Popen([str(args.app / "Contents/MacOS/Harbor"), "--harbor-ui-testing",
            "--harbor-disable-automatic-update-check", "--harbor-never-request-notification-authorization",
            "--harbor-user-defaults-suite", suite, "--harbor-application-support-directory", str(root / "support"),
            "--harbor-default-destination-path", str(root / "downloads"),
            "--harbor-torrent-destination-path", str(root / "torrents"),
            "--harbor-torrent-watch-folder-path", str(root / "watch")], env=env, stdout=app_log, stderr=app_log)
    def run(*arguments, code=0, input=None):
        result = subprocess.run([str(cli), *map(str, arguments), "--json"], env=env,
                                input=json.dumps(input) if input is not None else None,
                                text=True, capture_output=True, timeout=140)
        assert result.returncode == code, (arguments, result.returncode, result.stdout, result.stderr)
        payload = json.loads(result.stdout)
        assert payload["protocol"] == 1
        return payload["result"] if "result" in payload else payload["error"]
    def inspect(id): return run("inspect", id)
    def status(id, expected): return wait_for(lambda: inspect(id)["status"] in expected)
    try:
        fixture_info = wait_for(lambda: json.loads((root / "ready.json").read_text()) if (root / "ready.json").exists() else None)
        base = fixture_info["baseURL"]
        assert run("version")["version"] == "2.0.0"
        assert "help" in run("help")
        app = launch()
        time.sleep(3)
        run("list", code=3)
        assert not (root / "ipc/control.sock").exists(), "Access must be off by default"
        app.terminate(); app.wait(timeout=15)
        subprocess.run(["defaults", "write", suite, "cliAccessEnabled", "-bool", "true"], check=True)
        app = launch()
        wait_for(lambda: (root / "ipc/control.sock").exists())
        wait_for(lambda: run("doctor")["ready"])
        assert (root / "ipc").stat().st_mode & 0o777 == 0o700
        assert (root / "ipc/control.sock").stat().st_mode & 0o777 == 0o600
        assert run("list")["total"] == 0
        print("PASS default-disabled access, native CLI, readiness and private endpoint", flush=True)
        run("list", "--typo", "x", code=2)
        run("pause", code=2)
        run("inspect", uuid.uuid4(), code=1)
        original = run("settings", "get", "maxConcurrentDownloads")["value"]
        run("settings", "set", "maxConcurrentDownloads", "0", code=2)
        assert run("settings", "get", "maxConcurrentDownloads")["value"] == original
        run("settings", "set", "maxConcurrentDownloads", "2")
        assert run("settings", "get", "maxConcurrentDownloads")["value"] == 2
        run("settings", "set", "cliAccessEnabled", "true", code=2)
        key = str(uuid.uuid4())
        source = base + "/direct/slow.bin"
        added = run("add", source, "--paused", "--tags", "cli-test", "--request-id", key)
        id = added["id"]
        assert inspect(id)["status"] == "paused"
        assert run("add", source, "--paused", "--tags", "cli-test", "--request-id", key)["id"] == id
        run("add", base + "/direct/small.bin", "--request-id", key, code=2)
        assert run("list")["total"] == 1
        run("tags", "set", id, "one", "two")
        run("tags", "rename", "one", "renamed")
        assert inspect(id)["tags"] == ["renamed", "two"]
        run("tags", "delete", "two")
        run("limit", id, "download", "512")
        run("resume", id)
        status(id, ["downloading"])
        run("pause", id)
        status(id, ["paused"])
        run("resume", id)
        completed = run("wait", id, "--timeout", "60")
        assert hashlib.sha256(Path(completed["file"]).read_bytes()).hexdigest() == fixture_info["slowSHA256"]
        assert any(event["kind"] == "completed" for event in run("activity", id))
        run("trash", id, code=2)
        assert Path(completed["file"]).exists()
        run("remove", id)
        wait_for(lambda: run("list")["total"] == 0)
        assert Path(completed["file"]).exists(), "Remove must preserve files"
        print("PASS validation, settings, idempotent add, tags, limits, pause/resume and checksum", flush=True)
        secret = "private-header-not-for-output"
        protected = run("add", "--input", "-", input={"source": base + "/direct/small.bin", "paused": True,
            "headers": [{"name": "Authorization", "value": secret}], "name": "harbor-cli-trash-" + uuid.uuid4().hex + ".bin"})["id"]
        assert secret not in json.dumps(run("list"))
        run("resume", protected)
        file = Path(run("wait", protected)["file"])
        run("trash", protected, "--confirm-trash")
        wait_for(lambda: not file.exists())
        trashed = Path.home() / ".Trash" / file.name
        if trashed.exists(): trashed.unlink()  # Only the unique file created by this test.
        failed = run("add", base + "/errors/404.bin")["id"]
        status(failed, ["failed"])
        run("wait", failed, code=1)
        run("retry", failed)
        status(failed, ["failed"])
        run("clear", "failed")
        paused = run("add", base + "/direct/small.bin", "--paused")["id"]
        run("wait", paused, "--timeout", "1", code=5)
        run("cancel", paused)
        status(paused, ["cancelled"])
        print("PASS private headers, explicit Trash, failed/retry, timeout and cancel", flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: run("list"), range(16)))
        assert all(result["total"] == 1 for result in results)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(root / "ipc/control.sock")); client.sendall(b'{"protocol":99}\n')
            assert json.loads(client.recv(8192))["error"]["code"] == "invalid_argument"
        fragmented = subprocess.Popen([str(cli), "list", "--input", "-", "--json"], env=env,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        fragmented.stdin.write("{"); fragmented.stdin.flush()
        time.sleep(0.1)
        fragmented.stdin.write("}"); fragmented.stdin.close()
        assert json.loads(fragmented.stdout.read())["ok"]
        assert fragmented.wait(timeout=10) == 0
        installer = run("skill", "install")
        assert all(target["status"] == "current" for target in installer), installer
        assert len(installer) == 4
        claude = root / "home/.claude/skills/harbor/SKILL.md"
        claude.write_text("my edited skill")
        results = run("skill", "install", code=1)
        assert any(target["status"] == "conflict" for target in results)
        assert claude.read_text() == "my edited skill"
        run("skill", "uninstall", code=1)
        assert claude.read_text() == "my edited skill"
        assert not (root / "home/.agents/skills/harbor").exists()
        outside = root / "outside"; outside.mkdir()
        (root / "home/.agents/skills/harbor").symlink_to(outside, target_is_directory=True)
        run("skill", "install", code=1)
        assert not list(outside.iterdir()), "Installer must not follow a symlink"
        print("PASS concurrent clients, protocol rejection, skill install/update/remove conflicts and links", flush=True)
        run("settings", "set", "manifestImportEnabled", "true")
        manifest = root / "urls.txt"
        manifest.write_text(base + "/direct/small.bin\n" + base + "/direct/small.bin\ninvalid\n")
        batch = run("import", manifest, "--paused")
        assert len(batch["ids"]) == 1 and batch["skipped"] == 2, batch
        preview = run("preview", base + "/torrents/multi.torrent")
        assert len(preview["files"]) == 2
        torrent = run("add", base + "/torrents/multi.torrent", "--paused", "--files", "1")["id"]
        assert [f["selected"] for f in run("torrent", "files", torrent)["files"]] == [True, False]
        run("torrent", "select", torrent, "99", code=2)
        run("torrent", "select", torrent, "1", "2")
        assert all(f["selected"] for f in run("torrent", "files", torrent)["files"])
        assert run("add", base + "/torrents/multi.torrent", "--paused")["id"] == torrent
        print("PASS manifest import, torrent preview, file selection and duplicate detection", flush=True)
        webseed = run("add", base + "/torrents/webseed.torrent")["id"]
        downloaded = run("wait", webseed, "--timeout", "90")
        assert hashlib.sha256(Path(downloaded["file"]).read_bytes()).hexdigest() == fixture_info["smallSHA256"]
        run("torrent", "seed", webseed)
        status(webseed, ["seeding"])
        tracker = "http://127.0.0.1:1/cli-test-tracker"
        run("torrent", "tracker-add", webseed, tracker)
        assert any(t["url"] == tracker for t in run("torrent", "trackers", webseed))
        run("torrent", "tracker-remove", webseed, tracker)
        run("torrent", "reannounce", webseed)
        run("torrent", "stop-seeding", webseed)
        status(webseed, ["completed"])
        print("PASS torrent webseed checksum, trackers and seeding controls", flush=True)
        assert fixture_info["mediaAvailable"], "Local media fixture must be available"
        metadata = run("preview", base + "/media/page", "--kind", "mediaURL")
        assert metadata["title"].startswith("Harbor Synthetic Media")
        media = run("add", base + "/media/page", "--kind", "mediaURL", "--paused")["id"]
        assert run("media", "formats", media)["title"]
        run("resume", media)
        output = run("wait", media, "--timeout", "90")
        assert Path(output["file"]).stat().st_size > 0
        browser = run("add", base + "/errors/html.bin")["id"]
        status(browser, ["browserSessionRequired"])
        run("wait", browser, code=4)
        run("browser", browser, code=4)
        print("PASS media preview/download and browser interaction handoff", flush=True)
        # Crash and restart: saved additions and request receipts must agree.
        before = run("list")["total"]
        app.terminate(); app.wait(timeout=15)
        app = launch()
        def ready():
            result = subprocess.run([str(cli), "doctor", "--json"], env=env, text=True, capture_output=True, timeout=10)
            return result.returncode == 0 and json.loads(result.stdout).get("result", {}).get("ready")
        wait_for(ready)
        assert run("list")["total"] == before
        assert run("add", source, "--paused", "--tags", "cli-test", "--request-id", key)["id"] == id
        assert run("list")["total"] == before
        print("PASS restart persistence and durable add receipts", flush=True)
        report = {"root": str(root), "suite": suite, "pid": app.pid, "fixturePID": fixture.pid, "app": str(args.app)}
        (root / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report), flush=True)
    finally:
        if not args.keep:
            if app and app.poll() is None: app.terminate(); app.wait(timeout=15)
            fixture.terminate(); fixture.wait(timeout=15)
            subprocess.run(["defaults", "delete", suite], capture_output=True)
        print("Artifacts:", root, flush=True)

if __name__ == "__main__": main()
