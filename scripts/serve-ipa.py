#!/usr/bin/env python3
"""Serve built IPAs to a phone on the same network, with one-tap install links.

The page lists every `.ipa` in the directory with its version, build, size and
SHA-256, and each entry has buttons that hand the file to SideStore, AltStore or
a plain download. SideStore and AltStore accept a direct `.ipa` URL over plain
HTTP on the LAN, which is all a private local build needs.

An `itms-services` manifest is generated too, for clients that want the classic
OTA flow, but iOS only follows it over HTTPS with a trusted certificate: pass
`--public-url` with an HTTPS origin (a tunnel, for example) when you need that.

Usage:
    python3 scripts/serve-ipa.py dist/build-62
    python3 scripts/serve-ipa.py dist/build-62 --port 8080
    python3 scripts/serve-ipa.py dist/build-62 --public-url https://ipa.example.com
"""

from __future__ import annotations

import argparse
import hashlib
import html
import http.server
import plistlib
import socket
import socketserver
import sys
import urllib.parse
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

# A phone that opens the page from another device still needs an origin that
# resolves for it, so links use the address the server was reached at.
DEFAULT_PAGE = """<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ledger IPA</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 24px 16px 48px; font: 16px/1.5 -apple-system, "PingFang SC", sans-serif;
         background: #fbfaf8; color: #1c1b19; }
  @media (prefers-color-scheme: dark) { body { background: #121211; color: #f2f0ec; } }
  main { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  p.hint { margin: 0 0 24px; color: #6b665f; font-size: 14px; }
  .card { border: 1px solid #e3ded4; border-radius: 16px; padding: 16px; margin-bottom: 16px;
          background: #fff; }
  @media (prefers-color-scheme: dark) { .card { background: #1c1b19; border-color: #33312d; } }
  .name { font-weight: 600; word-break: break-all; }
  .meta { font-size: 13px; color: #6b665f; margin-top: 2px; }
  .meta code { font-size: 12px; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
  a.button { flex: 1 1 auto; text-align: center; padding: 11px 14px; border-radius: 12px;
             text-decoration: none; font-weight: 600; font-size: 15px; }
  a.primary { background: #2f5bd7; color: #fff; }
  a.secondary { background: #ece8e0; color: #1c1b19; }
  @media (prefers-color-scheme: dark) { a.secondary { background: #2a2825; color: #f2f0ec; } }
  .sha { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px;
         color: #8b857c; word-break: break-all; margin-top: 10px; }
  footer { font-size: 12px; color: #8b857c; margin-top: 24px; }
</style>
</head>
<body>
<main>
<h1>Ledger IPA</h1>
<p class="hint">手机与电脑在同一网络。先装好 SideStore / AltStore，再点安装。</p>
{cards}
<footer>由 scripts/serve-ipa.py 提供 · 仅限私有本地安装</footer>
</main>
</body>
</html>
"""


@dataclass
class IPA:
    path: Path
    name: str
    size: int
    bundle_id: str = ""
    display_name: str = ""
    version: str = ""
    build: str = ""
    minimum_os: str = ""
    sha256: str = ""
    digests: dict[str, str] = field(default_factory=dict)

    @property
    def label(self) -> str:
        version = self.version or "?"
        build = f" ({self.build})" if self.build else ""
        return f"{version}{build}"


def read_ipa_metadata(path: Path) -> dict[str, str]:
    """Read Payload/*.app/Info.plist out of the archive without unpacking it."""
    try:
        with zipfile.ZipFile(path) as archive:
            entries = [n for n in archive.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
            if not entries:
                return {}
            with archive.open(entries[0]) as handle:
                info = plistlib.load(handle)
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException):
        return {}
    return {
        "bundle_id": str(info.get("CFBundleIdentifier", "")),
        "display_name": str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or ""),
        "version": str(info.get("CFBundleShortVersionString", "")),
        "build": str(info.get("CFBundleVersion", "")),
        "minimum_os": str(info.get("MinimumOSVersion", "")),
    }


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe(path: Path) -> IPA:
    meta = read_ipa_metadata(path)
    return IPA(
        path=path,
        name=path.name,
        size=path.stat().st_size,
        sha256=sha256_of(path),
        **meta,
    )


def usable(address: str) -> bool:
    """Reject loopback and the fake ranges a VPN/TUN gives a virtual adapter."""
    prefixes = ("127.", "0.", "169.254.", "198.18.", "198.19.")
    return not address.startswith(prefixes)


def lan_addresses() -> list[str]:
    found: list[str] = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            address = info[4][0]
            if usable(address) and address not in found:
                found.append(address)
    except OSError:
        pass
    # Ask the routing table which local address reaches the internet; that is
    # the one a phone on the same Wi-Fi usually sees.
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        primary = probe.getsockname()[0]
        if usable(primary) and primary not in found:
            found.insert(0, primary)
    except OSError:
        pass
    finally:
        probe.close()
    return found


def manifest_xml(ipa: IPA, url: str) -> bytes:
    assets: dict[str, object] = {"kind": "software-package", "url": url}
    payload = {
        "items": [
            {
                "assets": [assets],
                "metadata": {
                    "bundle-identifier": ipa.bundle_id,
                    "bundle-version": ipa.version or "0",
                    "kind": "software",
                    "title": ipa.display_name or ipa.name,
                },
            }
        ]
    }
    return plistlib.dumps(payload)


def human_size(size: int) -> str:
    return f"{size / (1024 * 1024):.1f} MB"


def render(index: list[IPA], base: str) -> str:
    cards = []
    for ipa in index:
        ipa_url = f"{base}/{urllib.parse.quote(ipa.name)}"
        manifest = f"{base}/manifest/{urllib.parse.quote(ipa.name)}.plist"
        sidestore = "sidestore://install?url=" + urllib.parse.quote(ipa_url, safe="")
        altstore = "altstore://install?url=" + urllib.parse.quote(ipa_url, safe="")
        ota = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest, safe="")
        meta = " · ".join(
            part
            for part in (
                html.escape(ipa.display_name) if ipa.display_name else "",
                html.escape(ipa.bundle_id) if ipa.bundle_id else "",
                human_size(ipa.size),
                f"最低 iOS {html.escape(ipa.minimum_os)}" if ipa.minimum_os else "",
            )
            if part
        )
        cards.append(
            f"""<section class="card">
  <div class="name">{html.escape(ipa.name)}</div>
  <div class="meta">{html.escape(ipa.label)} · {meta}</div>
  <div class="actions">
    <a class="button primary" href="{html.escape(sidestore)}">用 SideStore 安装</a>
    <a class="button secondary" href="{html.escape(altstore)}">AltStore</a>
    <a class="button secondary" href="{html.escape(ipa_url)}" download>下载</a>
  </div>
  <div class="actions">
    <a class="button secondary" href="{html.escape(ota)}">OTA 清单（需 HTTPS）</a>
  </div>
  <div class="sha">SHA-256 {ipa.sha256}</div>
</section>"""
        )
    return DEFAULT_PAGE.replace("{cards}", "\n".join(cards))


class Handler(http.server.SimpleHTTPRequestHandler):
    index: list[IPA] = []
    by_name: dict[str, IPA] = {}
    public_url: str = ""

    def do_GET(self) -> None:  # noqa: N802 - http.server naming
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/index.html"):
            return self.send_page()
        if path.startswith("/manifest/"):
            return self.send_manifest(path[len("/manifest/") :])
        if path == "/healthz":
            return self.send_text("ok\n")
        return super().do_GET()

    def do_HEAD(self) -> None:  # noqa: N802 - http.server naming
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/index.html"):
            return self.send_page(head_only=True)
        if path.startswith("/manifest/"):
            return self.send_manifest(path[len("/manifest/") :], head_only=True)
        if path == "/healthz":
            return self.send_text("ok\n", head_only=True)
        return super().do_HEAD()

    def send_page(self, head_only: bool = False) -> None:
        body = render(self.index, self.base_url()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def send_text(self, text: str, head_only: bool = False) -> None:
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def send_manifest(self, raw_name: str, head_only: bool = False) -> None:
        name = urllib.parse.unquote(raw_name)
        ipa = self.by_name.get(name) or self.by_name.get(name.removesuffix(".plist"))
        if ipa is None:
            self.send_error(404, "no such IPA")
            return
        body = manifest_xml(ipa, f"{self.base_url()}/{urllib.parse.quote(ipa.name)}")
        self.send_response(200)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def base_url(self) -> str:
        if self.public_url:
            return self.public_url.rstrip("/")
        host = self.headers.get("Host") or f"{lan_addresses()[0] if lan_addresses() else '127.0.0.1'}:{self.server.server_address[1]}"
        return f"http://{host}"

    def guess_type(self, path: str) -> str:
        # One Content-Type per response: the archive is a download, never a
        # preview, and the OTA manifest is XML.
        if str(path).lower().endswith(".ipa"):
            return "application/octet-stream"
        if str(path).lower().endswith(".plist"):
            return "text/xml; charset=utf-8"
        return super().guess_type(path)

    def end_headers(self) -> None:
        # A malformed request line fails before parse_request sets self.path, and
        # send_error still goes through this override; without the default the
        # error response raised AttributeError instead of answering the client.
        if str(getattr(self, "path", "")).lower().split("?")[0].endswith(".ipa"):
            self.send_header("Content-Disposition", "attachment")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("  %s\n" % (fmt % args))


def main() -> int:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("directory", help="directory containing the .ipa files")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="0.0.0.0", help="bind address (default: all interfaces)")
    parser.add_argument(
        "--public-url",
        default="",
        help="origin to put in the page and manifests, for example an HTTPS tunnel",
    )
    options = parser.parse_args()

    root = Path(options.directory).resolve()
    if not root.is_dir():
        parser.error(f"not a directory: {root}")
    ipas = sorted(root.glob("*.ipa"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not ipas:
        parser.error(f"no .ipa in {root}")

    print(f"Reading {len(ipas)} IPA(s) in {root} ...")
    index = [describe(ipa) for ipa in ipas]

    Handler.index = index
    Handler.by_name = {ipa.name: ipa for ipa in index}
    Handler.public_url = options.public_url
    socketserver.TCPServer.allow_reuse_address = True

    handler = lambda *a, **kw: Handler(*a, directory=str(root), **kw)  # noqa: E731
    with socketserver.ThreadingTCPServer((options.host, options.port), handler) as server:
        print(f"\nServing {root}")
        for ipa in index:
            print(f"  {ipa.name}  {ipa.label}  ({human_size(ipa.size)})")
        print()
        if options.public_url:
            print(f"  page    {options.public_url.rstrip('/')}/")
        else:
            for host in lan_addresses() or ["127.0.0.1"]:
                print(f"  page    http://{host}:{options.port}/")
        print("\nOpen the page on the phone, then tap 用 SideStore 安装.")
        print("The phone and this Mac must be on the same network.\n")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
