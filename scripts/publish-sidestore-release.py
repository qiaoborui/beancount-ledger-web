#!/usr/bin/env python3
"""Publish a packaged IPA to the public SideStore source.

The source lives in a separate public repository (by default
qiaoborui/beancount-ledger-releases): `sidestore/source.json` lists every
version, and each version's IPA is an asset of a GitHub Release tagged
`v<version>` in that repository. This script uploads one IPA and prepends it
to the source, so phones that added the source see the update in SideStore.

Run it after `scripts/build-ios-ipa.sh` has packaged a release (see the iOS
App Version section of AGENTS.md). It refuses to publish:

- without `--public`: publishing makes the IPA publicly downloadable, which
  App/LedgerMobile/Runtime/THIRD_PARTY.md flags as an open licensing issue;
- an IPA whose version has no pushed `v<version>` tag, or is not the newest tag;
- an IPA not built from that tag's commit in a clean worktree, or whose commit
  is not on origin/main (read from the `build-info.txt` next to the IPA);
- a version already in the source, or a build number not above every listed one.

The live source starts with no apps, because SideStore rejects a source whose
app has no versions. The first publish inserts the app from
`sidestore/app.json` in the releases repository.

If the release was created but the source push failed, run the same command
again: an existing release whose uploaded asset has the IPA's name and sha256
is reused, and only the source is updated.

Usage:
    python3 scripts/publish-sidestore-release.py --public \\
        dist/0.5.0-55/LedgerMobile-0.5.0-55-SideStore.ipa --notes notes.md
    python3 scripts/publish-sidestore-release.py --public IPA --notes notes.md --dry-run
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPO = "qiaoborui/beancount-ledger-releases"
BUNDLE_ID = "com.qiaoborui.ledger.mobile"
SOURCE_PATH = "sidestore/source.json"
APP_TEMPLATE_PATH = "sidestore/app.json"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
APP_INFO_PLIST = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")


class PublishError(Exception):
    pass


def read_ipa_metadata(path: Path) -> dict[str, str]:
    """Version, build, bundle id and minimum OS of the app inside an IPA."""
    try:
        with zipfile.ZipFile(path) as archive:
            names = [name for name in archive.namelist() if APP_INFO_PLIST.match(name)]
            if len(names) != 1:
                raise PublishError(f"{path.name}: expected one Payload/*.app/Info.plist, found {len(names)}")
            with archive.open(names[0]) as handle:
                info = plistlib.load(handle)
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise PublishError(f"{path}: not a readable IPA ({error})") from error
    try:
        return {
            "bundleIdentifier": str(info["CFBundleIdentifier"]),
            "version": str(info["CFBundleShortVersionString"]),
            "buildVersion": str(info["CFBundleVersion"]),
            "minOSVersion": str(info.get("MinimumOSVersion", "")),
        }
    except KeyError as error:
        raise PublishError(f"{path.name}: Info.plist is missing {error}") from error


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_app(source: dict, bundle_id: str) -> dict | None:
    apps = [app for app in source.get("apps", []) if app.get("bundleIdentifier") == bundle_id]
    if len(apps) > 1:
        raise PublishError(f"source lists {len(apps)} apps with bundle id {bundle_id}")
    return apps[0] if apps else None


def add_version(source: dict, bundle_id: str, entry: dict, template: dict | None = None) -> dict:
    """Return a copy of the source with `entry` as the app's newest version.

    SideStore rejects the whole source when an app has no versions, so the
    app is kept out of the source until its first version: then `template`
    (the app metadata without versions) is inserted and featured. The legacy
    top-level fields (version, versionDate, ...) that older AltStore clients
    read are refreshed from the new entry.
    """
    updated = copy.deepcopy(source)
    app = find_app(updated, bundle_id)
    if app is None:
        if template is None:
            raise PublishError(f"source has no app {bundle_id} and no {APP_TEMPLATE_PATH} to add it from")
        if template.get("bundleIdentifier") != bundle_id:
            raise PublishError(f"{APP_TEMPLATE_PATH} describes {template.get('bundleIdentifier')}, not {bundle_id}")
        app = copy.deepcopy(template)
        app["versions"] = []
        updated.setdefault("apps", []).append(app)
        featured = updated.setdefault("featuredApps", [])
        if bundle_id not in featured:
            featured.append(bundle_id)
    versions = app.setdefault("versions", [])
    for existing in versions:
        if existing.get("version") == entry["version"]:
            raise PublishError(f"version {entry['version']} is already in the source")
    builds = [int(existing["buildVersion"]) for existing in versions if str(existing.get("buildVersion", "")).isdigit()]
    if builds and int(entry["buildVersion"]) <= max(builds):
        raise PublishError(
            f"build {entry['buildVersion']} is not above the newest listed build {max(builds)}; "
            "SideStore would not see it as an update"
        )
    newest = [existing["version"] for existing in versions if VERSION.match(str(existing.get("version", "")))]
    if newest and version_key(entry["version"]) <= max(version_key(v) for v in newest):
        raise PublishError(f"version {entry['version']} is not above the newest listed version")
    versions.insert(0, entry)
    app["version"] = entry["version"]
    app["versionDate"] = entry["date"]
    app["versionDescription"] = entry["localizedDescription"]
    app["downloadURL"] = entry["downloadURL"]
    app["size"] = entry["size"]
    return updated


def render_source(source: dict) -> str:
    return json.dumps(source, ensure_ascii=False, indent=2) + "\n"


def run(args: list[str], cwd: Path | None = None, capture: bool = True) -> str:
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=capture)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        raise PublishError(f"{' '.join(args[:3])} failed: {detail}")
    return result.stdout if capture else ""


def parse_build_info(text: str) -> dict[str, str]:
    """`Source:` commit and `Worktree:` state recorded by build-ios-ipa.sh."""
    info = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if sep and key in ("Source", "Worktree"):
            info[key] = value.strip()
    if not COMMIT.match(info.get("Source", "")):
        raise PublishError("build-info.txt has no Source commit; package the release with scripts/build-ios-ipa.sh")
    if info.get("Worktree") != "clean":
        raise PublishError("build-info.txt does not record a clean worktree; package from a clean checkout of the tag")
    return info


def remote_tag_commit(listing: str, tag: str) -> str | None:
    """Commit a tag points to in `git ls-remote` output (peeled when annotated)."""
    refs = dict(reversed(line.split("\t", 1)) for line in listing.splitlines() if "\t" in line)
    return refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")


def check_tag(version: str, source_commit: str) -> None:
    tags = run(["git", "-C", str(ROOT), "tag", "--list", "v[0-9]*.[0-9]*.[0-9]*"]).split()
    versions = [tag[1:] for tag in tags if VERSION.match(tag[1:])]
    if version not in versions:
        raise PublishError(f"no local tag v{version}; cut the release first (AGENTS.md, iOS App Version)")
    newest = max(versions, key=version_key)
    if newest != version:
        raise PublishError(f"v{version} is not the newest release tag (v{newest})")
    tag = f"v{version}"
    local = run(["git", "-C", str(ROOT), "rev-parse", f"{tag}^{{commit}}"]).strip()
    if local != source_commit:
        raise PublishError(f"the IPA was built from {source_commit[:12]}, but {tag} points to {local[:12]}")
    listing = run(["git", "-C", str(ROOT), "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"])
    remote = remote_tag_commit(listing, tag)
    if remote is None:
        raise PublishError(f"tag {tag} is not pushed to origin")
    if remote != local:
        raise PublishError(f"tag {tag} points to {local[:12]} here but {remote[:12]} on origin")
    run(["git", "-C", str(ROOT), "fetch", "--quiet", "origin", "main"])
    merged = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", local, "FETCH_HEAD"])
    if merged.returncode != 0:
        raise PublishError(f"{tag} ({local[:12]}) is not on origin/main; merge the release before publishing")


def verify_asset(release: dict, name: str, digest: str) -> None:
    """The release must carry an uploaded asset `name` with exactly this sha256."""
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if not matches:
        raise PublishError(f"release {release.get('tagName')} has no asset {name}")
    asset = matches[0]
    if asset.get("state") != "uploaded":
        raise PublishError(f"asset {name} is {asset.get('state')}, not uploaded")
    if asset.get("digest") != f"sha256:{digest}":
        raise PublishError(f"asset {name} has digest {asset.get('digest')}, but the local IPA is sha256:{digest}")


def existing_release(repo: str, tag: str) -> dict | None:
    result = subprocess.run(
        ["gh", "release", "view", tag, "-R", repo, "--json", "tagName,assets"],
        text=True, capture_output=True,
    )
    if result.returncode != 0:
        if "not found" in (result.stderr or "").lower():
            return None
        raise PublishError(f"gh release view {tag} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def check_download(url: str, size: int) -> None:
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "ledger-sidestore-publish"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            length = response.headers.get("Content-Length")
    except (urllib.error.URLError, OSError) as error:
        raise PublishError(f"{url} is not downloadable yet ({error}); the release exists, so "
                           "run the same command again to update the source") from error
    if length is not None and int(length) != size:
        raise PublishError(f"{url} serves {length} bytes, expected {size}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", type=Path, help="IPA packaged by scripts/build-ios-ipa.sh")
    parser.add_argument("--notes", type=Path, required=True, help="Markdown release notes (Chinese, user facing)")
    parser.add_argument("--repo", default=os.environ.get("LEDGER_RELEASES_REPO", DEFAULT_REPO))
    parser.add_argument("--public", action="store_true",
                        help="confirm the IPA becomes publicly downloadable (see THIRD_PARTY.md)")
    parser.add_argument("--dry-run", action="store_true", help="print the new source.json, publish nothing")
    options = parser.parse_args()

    if not options.public:
        print("Refusing to publish without --public: the IPA becomes publicly downloadable, and "
              "App/LedgerMobile/Runtime/THIRD_PARTY.md records an unresolved redistribution "
              "licensing issue.", file=sys.stderr)
        return 2
    try:
        ipa = options.ipa.resolve()
        meta = read_ipa_metadata(ipa)
        if meta["bundleIdentifier"] != BUNDLE_ID:
            raise PublishError(f"{ipa.name} is {meta['bundleIdentifier']}, not {BUNDLE_ID}")
        if not VERSION.match(meta["version"]) or not meta["buildVersion"].isdigit():
            raise PublishError(f"unexpected version {meta['version']} ({meta['buildVersion']})")
        notes = options.notes.read_text(encoding="utf-8").strip()
        if not notes:
            raise PublishError(f"{options.notes} is empty")
        digest = sha256_of(ipa)
        sidecar = ipa.with_name(ipa.name + ".sha256")
        if sidecar.exists() and sidecar.read_text().split()[0] != digest:
            raise PublishError(f"{sidecar.name} does not match {ipa.name}")
        build_info = ipa.with_name("build-info.txt")
        if not build_info.is_file():
            raise PublishError(f"no build-info.txt next to {ipa.name}; package with scripts/build-ios-ipa.sh")
        source_commit = parse_build_info(build_info.read_text(encoding="utf-8"))["Source"]
        check_tag(meta["version"], source_commit)

        tag = f"v{meta['version']}"
        size = ipa.stat().st_size
        url = f"https://github.com/{options.repo}/releases/download/{tag}/{ipa.name}"
        entry = {
            "version": meta["version"],
            "buildVersion": meta["buildVersion"],
            "date": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": notes,
            "downloadURL": url,
            "size": size,
            "sha256": digest,
        }
        if meta["minOSVersion"]:
            entry["minOSVersion"] = meta["minOSVersion"]

        with tempfile.TemporaryDirectory(prefix="ledger-sidestore-") as temp:
            checkout = Path(temp) / "releases"
            run(["gh", "repo", "clone", options.repo, str(checkout), "--", "--depth", "1", "--quiet"])
            source_file = checkout / SOURCE_PATH
            source = json.loads(source_file.read_text(encoding="utf-8"))
            template_file = checkout / APP_TEMPLATE_PATH
            template = json.loads(template_file.read_text(encoding="utf-8")) if template_file.is_file() else None
            updated = add_version(source, BUNDLE_ID, entry, template)
            if options.dry_run:
                print(render_source(updated), end="")
                print(f"\nDry run: would release {tag} on {options.repo} with {ipa.name} ({size} bytes, sha256 {digest}).",
                      file=sys.stderr)
                return 0

            release = existing_release(options.repo, tag)
            if release is None:
                assets = [str(ipa)] + ([str(sidecar)] if sidecar.exists() else [])
                run(["gh", "release", "create", tag, "-R", options.repo, "--target", "main",
                     "--title", f"Ledger {meta['version']}", "--notes-file", str(options.notes), *assets])
                print(f"Created release {tag} on {options.repo}.")
                release = existing_release(options.repo, tag)
                if release is None:
                    raise PublishError(f"release {tag} was created but cannot be read back; run again")
                verify_asset(release, ipa.name, digest)
            else:
                verify_asset(release, ipa.name, digest)
                print(f"Release {tag} already has this {ipa.name}; updating the source only.")
            check_download(url, size)

            source_file.write_text(render_source(updated), encoding="utf-8")
            run(["git", "-C", str(checkout), "add", SOURCE_PATH])
            run(["git", "-C", str(checkout), "commit", "--quiet", "-m",
                 f"Release Ledger {meta['version']} ({meta['buildVersion']})"])
            run(["git", "-C", str(checkout), "push", "--quiet", "origin", "HEAD:main"])
        print(f"Published Ledger {meta['version']} ({meta['buildVersion']}) to "
              f"https://raw.githubusercontent.com/{options.repo}/main/{SOURCE_PATH}")
        return 0
    except PublishError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
