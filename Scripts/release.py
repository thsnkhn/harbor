#!/usr/bin/env python3
"""Prepare processor-specific packages locally. Publishing is a separate command."""

import argparse
import copy
import datetime
import email.utils
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/release"
APP = ROOT / "build/HarborDerivedData/Build/Products/Release/Harbor.app"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
LEGACY_FEED = "https://thsnkhn.github.io/harbor/appcast.xml"
REPO = "thsnkhn/harbor"
ARCHITECTURES = (("x86_64", "Intel", "1"), ("arm64", "Apple-Silicon", "2"))
ET.register_namespace("sparkle", SPARKLE)


def run(*args, capture=False, **kwargs):
    result = subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT,
                            text=True, stdout=subprocess.PIPE if capture else None, **kwargs)
    return result.stdout.strip() if capture else None


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def settings():
    project = json.loads(run("plutil", "-convert", "json", "-o", "-", ROOT / "Harbor.xcodeproj/project.pbxproj", capture=True))
    objects = project["objects"]
    target = next(value for value in objects.values() if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Harbor")
    configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
    return next(objects[key]["buildSettings"] for key in configs if objects[key]["name"] == "Release")


def tools():
    directory = Path(os.environ.get("SPARKLE_BIN_DIR", ROOT / "build/HarborDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"))
    if not (directory / "sign_update").is_file():
        raise RuntimeError("Resolve the Sparkle package or set SPARKLE_BIN_DIR before preparing a release.")
    return directory


def feed_data(path=None):
    if path:
        return Path(path).read_bytes()
    with urllib.request.urlopen(LEGACY_FEED, timeout=30) as response:
        return response.read()


def build_tuple(value):
    return tuple(int(part) for part in value.split("."))


def create_item(package, version, notes_url):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    for key, value in (("version", package["build"]), ("shortVersionString", version),
                       ("minimumSystemVersion", package["minimum_system"]), ("releaseNotesLink", notes_url)):
        ET.SubElement(item, f"{{{SPARKLE}}}{key}").text = value
    if package["architecture"] == "arm64":
        ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "enclosure", {
        "url": package["url"], "length": str(package["length"]), "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": package["signature"],
    })
    return item


def generate_feeds(packages, version, previous_data, output):
    if len(packages) != 2 or {item["architecture"] for item in packages} != {"arm64", "x86_64"}:
        raise RuntimeError("Both processor packages are required before creating update feeds.")
    for architecture, label, suffix in ARCHITECTURES:
        package = next(item for item in packages if item["architecture"] == architecture)
        if package["file"] != f"Harbor-{version}-{label}.dmg" or package["build"].split(".")[-1] != suffix:
            raise RuntimeError("A package name or build number does not match its processor.")
    previous = ET.fromstring(previous_data).findall("channel/item")
    newest_previous = max((build_tuple(item.findtext(f"{{{SPARKLE}}}version", "0")) for item in previous), default=(0,))
    if min(build_tuple(package["build"]) for package in packages) <= newest_previous:
        raise RuntimeError("The new internal build numbers must exceed every build in the existing feed.")
    notes_url = f"https://thsnkhn.github.io/harbor/updates/Harbor-{version}.md"
    for architecture in (None, "x86_64", "arm64"):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Harbor"
        # The arm64 item is newer, so current universal clients prefer it on Apple Silicon.
        for package in sorted(packages, key=lambda value: build_tuple(value["build"]), reverse=True):
            if architecture is None or package["architecture"] == architecture:
                channel.append(create_item(package, version, notes_url))
        for item in previous:
            url = item.find("enclosure").get("url", "")
            arm_required = "arm64" in {value.strip().lower() for value in item.findtext(f"{{{SPARKLE}}}hardwareRequirements", "").split(",")}
            if architecture == "x86_64" and (arm_required or url.endswith("-Apple-Silicon.dmg")):
                continue
            if architecture == "arm64" and url.endswith("-Intel.dmg"):
                continue
            channel.append(copy.deepcopy(item))
        # Keep previous compatible releases for older macOS versions and late updaters.
        for item in channel.findall("item")[8:]:
            channel.remove(item)
        name = "appcast.xml" if architecture is None else f"appcast-{architecture}.xml"
        ET.indent(root, space="    ")
        ET.ElementTree(root).write(Path(output) / name, encoding="utf-8", xml_declaration=True)
    # TODO: Re-enable per-processor delta updates after validating universal-to-native migrations.


def verify_app(app, architecture, build, project):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {"CFBundleIdentifier": project["PRODUCT_BUNDLE_IDENTIFIER"],
                "CFBundleShortVersionString": project["MARKETING_VERSION"], "CFBundleVersion": build,
                "SUPublicEDKey": project["SPARKLE_PUBLIC_ED_KEY"], "SUFeedURL": LEGACY_FEED}
    for key, value in expected.items():
        if info.get(key) != value:
            raise RuntimeError(f"The built app has an unexpected {key}.")
    for executable in (app / "Contents/MacOS/Harbor", app / "Contents/Helpers/harbor", app / "Contents/PlugIns/HarborSafariExtension.appex/Contents/MacOS/HarborSafariExtension"):
        if run("lipo", "-archs", executable, capture=True) != architecture:
            raise RuntimeError(f"Incorrect processor in {executable.name}.")
    for runtime in ("TorrentRuntime", "MediaRuntime", "VPNRuntime"):
        root = app / "Contents/Resources" / runtime
        other = "arm64" if architecture == "x86_64" else "x86_64"
        if not (root / architecture).is_dir() or (root / other).exists():
            raise RuntimeError(f"Incorrect processor directories in {runtime}.")
        executables = {"TorrentRuntime": ("aria2-next",), "MediaRuntime": ("deno", "ffmpeg", "ffprobe"),
                       "VPNRuntime": ("harbor-vpn", "harbor-openvpn")}[runtime]
        binaries = [root / architecture / "bin" / name for name in executables]
        binaries += list((root / architecture).rglob("*.dylib"))
        for binary in binaries:
            if run("lipo", "-archs", binary, capture=True) != architecture:
                raise RuntimeError(f"The {runtime} package contains a mismatched binary: {binary.name}")
    sparkle_info = app / "Contents/Frameworks/Sparkle.framework/Resources/Info.plist"
    with sparkle_info.open("rb") as stream:
        if build_tuple(plistlib.load(stream)["CFBundleShortVersionString"]) < (2, 9):
            raise RuntimeError("The migration requires Sparkle 2.9 or later.")
    media_helper = app / "Contents/Resources/MediaRuntime/bin/yt-dlp"
    if set(run("lipo", "-archs", media_helper, capture=True).split()) != {"arm64", "x86_64"}:
        raise RuntimeError("Keep the shared yt-dlp executable universal to preserve its Python payload.")
    run("codesign", "--verify", "--deep", "--strict", app)
    # Deep verification accepts ad-hoc helpers, which cannot pass release notarization.
    run("codesign", "--verify", "--strict", "-R",
        '=anchor apple generic and certificate leaf[subject.OU] = "2837P98423"',
        media_helper)
    run("codesign", "--verify", "--strict", "-R",
        '=anchor apple generic and certificate leaf[subject.OU] = "2837P98423"',
        app / "Contents/Helpers/harbor")
    return info


def verify_dmg(path, architecture, build, project):
    with tempfile.TemporaryDirectory(prefix="harbor-package-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, path)
        try:
            return verify_app(mount / "Harbor.app", architecture, build, project)
        finally:
            run("hdiutil", "detach", mount)


def submit_notarization(path, profile):
    result = json.loads(run("xcrun", "notarytool", "submit", path, "--keychain-profile", profile,
                            "--wait", "--output-format", "json", capture=True))
    if result.get("status") != "Accepted":
        raise RuntimeError(f"Apple rejected notarization for {Path(path).name}: {result.get('status')} (submission {result.get('id')}).")


def notarize(path, profile):
    submit_notarization(path, profile)
    run("xcrun", "stapler", "staple", path)
    run("xcrun", "stapler", "validate", path)


def prepare(args):
    project = settings()
    version = project["MARKETING_VERSION"]
    base_build = project["CURRENT_PROJECT_VERSION"]
    if not str(base_build).isdigit():
        raise RuntimeError("Keep CURRENT_PROJECT_VERSION as the increasing integer release number.")
    sparkle_tools = tools()
    public_key = run(sparkle_tools / "generate_keys", "-p", capture=True)
    if public_key != project["SPARKLE_PUBLIC_ED_KEY"]:
        raise RuntimeError("The existing Sparkle signing key does not match the app. Do not replace either key.")
    previous = feed_data(args.previous_appcast)
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    (OUTPUT / "previous-appcast.xml").write_bytes(previous)
    packages = []
    for architecture, label, suffix in ARCHITECTURES:
        build = f"{base_build}.{suffix}"
        environment = dict(os.environ, HARBOR_BUILD_ARCH=architecture, HARBOR_BUILD_NUMBER=build,
                           CONFIGURATION="Release", CODE_SIGNING_ALLOWED="YES", SIGN_TORRENT_RUNTIME="NO",
                           SIGNING_IDENTITY=args.signing_identity, DEVELOPMENT_TEAM="2837P98423")
        run("sh", ROOT / "Scripts/build-dmg.sh", env=environment)
        info = verify_app(APP, architecture, build, project)
        if args.smoke:
            run("sh", ROOT / "Scripts/smoke-release.sh", APP)
        dmg = OUTPUT / f"Harbor-{version}-{label}.dmg"
        if args.notarize:
            with tempfile.TemporaryDirectory(prefix="harbor-notary-") as temporary:
                archive = Path(temporary) / "Harbor.zip"
                run("ditto", "-c", "-k", "--keepParent", APP, archive)
                submit_notarization(archive, args.notary_profile)
                run("xcrun", "stapler", "staple", APP)
                # Repackage the stapled app without building or retaining a second app.
                with tempfile.TemporaryDirectory(prefix="harbor-dmg-") as temporary:
                    staging = Path(temporary)
                    run("ditto", APP, staging / "Harbor.app")
                    (staging / "Applications").symlink_to("/Applications")
                    dmg.unlink()
                    run("hdiutil", "create", "-volname", "Harbor", "-srcfolder", staging, "-format", "UDZO", dmg)
                run("codesign", "--force", "--sign", args.signing_identity, "--timestamp", dmg)
            notarize(dmg, args.notary_profile)
        verify_dmg(dmg, architecture, build, project)
        signature = run(sparkle_tools / "sign_update", "-p", dmg, capture=True)
        run(sparkle_tools / "sign_update", "--verify", dmg, signature)
        packages.append(dict(architecture=architecture, file=dmg.name, build=build, length=dmg.stat().st_size,
                             sha256=digest(dmg), signature=signature, minimum_system=info["LSMinimumSystemVersion"],
                             url=f"https://github.com/{REPO}/releases/download/v{version}/{dmg.name}"))
    generate_feeds(packages, version, previous, OUTPUT)
    notes = Path(args.notes_file).read_text() if args.notes_file else f"Harbor {version}\n"
    (OUTPUT / f"Harbor-{version}.md").write_text(notes)
    manifest = dict(version=version, commit=run("git", "rev-parse", "HEAD", capture=True),
                    dirty=bool(run("git", "status", "--porcelain", capture=True)),
                    previous_feed_sha256=hashlib.sha256(previous).hexdigest(), notarized=args.notarize, smoke_tested=args.smoke,
                    packages=packages)
    (OUTPUT / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    intel, arm = packages
    (OUTPUT / "homebrew-urls.rb").write_text(
        f'arch arm: "Apple-Silicon", intel: "Intel"\nversion "{version}"\n'
        f'on_arm do\n  sha256 "{arm["sha256"]}"\nend\n'
        f'on_intel do\n  sha256 "{intel["sha256"]}"\nend\n'
        f'url "https://github.com/{REPO}/releases/download/v#{{version}}/Harbor-#{{version}}-#{{arch}}.dmg"\n'
    )
    print(f"Prepared both packages and three feeds in {OUTPUT}. Nothing was published.")


def publish(args):
    directory = Path(args.directory).resolve()
    manifest = json.loads((directory / "release.json").read_text())
    # All checks precede tag creation, uploads, or changes to the live feed.
    if manifest["dirty"] or run("git", "status", "--porcelain", capture=True):
        raise RuntimeError("Prepare the final packages from a clean committed tree before publishing.")
    if manifest["commit"] != run("git", "rev-parse", "HEAD", capture=True):
        raise RuntimeError("The prepared packages belong to another commit. Prepare them again.")
    if not manifest["notarized"]:
        raise RuntimeError("These packages are local previews. Prepare with --notarize before publishing.")
    if not manifest.get("smoke_tested", False):
        raise RuntimeError("Run preparation with --smoke before publishing, as required by the release smoke test.")
    if hashlib.sha256(feed_data()).hexdigest() != manifest["previous_feed_sha256"]:
        raise RuntimeError("The live feed changed after preparation. Prepare again to preserve its updates.")
    for package in manifest["packages"]:
        path = directory / package["file"]
        if digest(path) != package["sha256"]:
            raise RuntimeError(f"The prepared package changed: {path.name}")
        run("codesign", "--verify", "--strict", path)
        verify_dmg(path, package["architecture"], package["build"], settings())
        run("xcrun", "stapler", "validate", path)
        run(tools() / "sign_update", "--verify", path, package["signature"])
    # Rebuild the feeds from signed package metadata; do not publish hand-edited routing.
    generate_feeds(manifest["packages"], manifest["version"], (directory / "previous-appcast.xml").read_bytes(), directory)
    with tempfile.TemporaryDirectory(prefix="harbor-pages-") as temporary:
        pages = Path(temporary) / "pages"
        run("git", "clone", "--single-branch", "--branch", "gh-pages", run("git", "remote", "get-url", "origin", capture=True), pages)
        if digest(pages / "appcast.xml") != manifest["previous_feed_sha256"]:
            raise RuntimeError("The feed changed before publication. Prepare again.")
        tag = f'v{manifest["version"]}'
        existing = subprocess.run(["git", "rev-parse", "--verify", f"refs/tags/{tag}"], cwd=ROOT,
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if existing.returncode == 0:
            if run("git", "rev-list", "-n", "1", tag, capture=True) != manifest["commit"]:
                raise RuntimeError("The release tag points to another commit.")
        else:
            run("git", "tag", "-s", tag, "-m", f'Harbor {manifest["version"]}')
        run("git", "push", "origin", tag)
        release = subprocess.run(["gh", "release", "view", tag, "--repo", REPO], cwd=ROOT,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if release.returncode != 0:
            run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--title", f'Harbor {manifest["version"]}',
                "--notes-file", directory / f'Harbor-{manifest["version"]}.md')
        run("gh", "release", "upload", tag, *(directory / item["file"] for item in manifest["packages"]), "--repo", REPO)
        for name in ("appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml"):
            shutil.copy2(directory / name, pages / name)
        (pages / "updates").mkdir(exist_ok=True)
        shutil.copy2(directory / f'Harbor-{manifest["version"]}.md', pages / "updates")
        run("git", "-C", pages, "add", "appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml", "updates")
        run("git", "-C", pages, "commit", "-m", f'Publish Harbor {manifest["version"]}')
        run("git", "-C", pages, "push", "origin", "gh-pages")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    local = commands.add_parser("prepare", help="Build and sign both packages locally; no publication")
    local.add_argument("--previous-appcast", help="Use a saved existing appcast instead of downloading it")
    local.add_argument("--notes-file")
    local.add_argument("--notarize", action="store_true", help="Also submit the packages to Apple for notarization")
    local.add_argument("--smoke", action="store_true", help="Run the existing isolated release smoke test for each processor")
    local.add_argument("--notary-profile", default="XCode Notary")
    local.add_argument("--signing-identity", default="Developer ID Application: ENOU Labs LLC (2837P98423)")
    remote = commands.add_parser("publish", help="Explicitly publish previously notarized packages and feeds")
    remote.add_argument("directory", nargs="?", default=str(OUTPUT))
    args = parser.parse_args()
    try:
        (prepare if args.command == "prepare" else publish)(args)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
