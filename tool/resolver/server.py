#!/usr/bin/env python3
"""Minimal yt-dlp resolver for maiDL.

The phone never downloads from YouTube/TikTok/Instagram directly. It asks this
service to extract a single-file media URL, then streams that URL back through
the service, which keeps signed, IP-bound and header-gated URLs working.

    python3 -m pip install -r tool/resolver/requirements.txt
    python3 tool/resolver/server.py --host 0.0.0.0 --port 8080

Then set the resolver in maiDL to http://<this computer's LAN IP>:8080.

There is no authentication: run it on a trusted network or behind a proxy.
Set MAIDL_YTDLP_COOKIES=/path/to/cookies.txt for login-gated sources.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

try:
    import yt_dlp
except ImportError:  # pragma: no cover - startup guard
    sys.exit("Install yt-dlp first: python3 -m pip install -r tool/resolver/requirements.txt")

TOKEN_TTL_SECONDS = 30 * 60
TOKENS: dict[str, dict] = {}


def prune_tokens() -> None:
    cutoff = time.time() - TOKEN_TTL_SECONDS
    for token, entry in list(TOKENS.items()):
        if entry["created"] < cutoff:
            TOKENS.pop(token, None)


def safe_filename(info: dict, fmt: dict) -> str:
    title = str(info.get("title") or "maiDL")
    base = re.sub(r"[^A-Za-z0-9._ ()-]", "_", title).strip().strip(".") or "maiDL"
    extension = str(fmt.get("ext") or "").strip().strip(".")
    if extension and not base.lower().endswith("." + extension.lower()):
        base = f"{base}.{extension}"
    return base[:120]


def pick_format(info: dict) -> dict:
    formats = info.get("formats") or []
    candidates = [
        fmt
        for fmt in formats
        if fmt.get("url")
        and str(fmt.get("protocol") or "").lower().startswith("http")
    ]
    progressive = [
        fmt
        for fmt in candidates
        if fmt.get("vcodec") not in (None, "none")
        and fmt.get("acodec") not in (None, "none")
    ]
    pool = progressive or candidates
    if not pool:
        raw = info.get("url")
        if not raw:
            raise ValueError("no downloadable media found")
        return {"url": raw, "ext": info.get("ext") or "mp4"}
    return max(pool, key=lambda fmt: fmt.get("height") or 0)


def extract(url: str) -> tuple[dict, dict]:
    options = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "socket_timeout": 30,
        "format": "best[acodec!=none][vcodec!=none]/best",
    }
    cookies = os.environ.get("MAIDL_YTDLP_COOKIES")
    if cookies:
        options["cookiefile"] = cookies

    with yt_dlp.YoutubeDL(options) as ydl:
        info = ydl.extract_info(url, download=False)

    if info.get("_type") == "playlist":
        entries = info.get("entries") or []
        if not entries:
            raise ValueError("the link contains no media")
        info = entries[0]

    fmt = pick_format(info)
    headers = fmt.get("http_headers") or info.get("http_headers") or {}
    return info, {**fmt, "http_headers": headers}


class Handler(BaseHTTPRequestHandler):
    server_version = "maiDLResolver/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        if urlparse.urlparse(self.path).path.rstrip("/") != "/resolve":
            self._json(404, {"error": {"code": "not_found"}})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            link = str(payload.get("url") or "").strip()
            parsed = urlparse.urlparse(link)
            if parsed.scheme not in ("http", "https") or not parsed.hostname:
                raise ValueError("url must be an http(s) link")
        except Exception as error:  # noqa: BLE001
            self._json(400, {"error": {"code": "invalid_request", "message": str(error)}})
            return

        try:
            info, fmt = extract(link)
        except Exception as error:  # noqa: BLE001
            sys.stderr.write(f"resolve failed: {error}\n")
            self._json(502, {"error": {"code": "extract_failed", "message": str(error)}})
            return

        prune_tokens()
        token = uuid.uuid4().hex
        host = self.headers.get("Host") or (
            f"{self.server.server_address[0]}:{self.server.server_address[1]}"
        )
        proto = self.headers.get("X-Forwarded-Proto", "http")
        TOKENS[token] = {
            "url": fmt["url"],
            "headers": fmt.get("http_headers") or {},
            "filename": safe_filename(info, fmt),
            "created": time.time(),
        }
        self._json(
            200,
            {
                "url": f"{proto}://{host}/media/{token}",
                "fileName": TOKENS[token]["filename"],
            },
        )

    def do_HEAD(self) -> None:  # noqa: N802
        self._proxy(head_only=True)

    def do_GET(self) -> None:  # noqa: N802
        self._proxy(head_only=False)

    def _proxy(self, head_only: bool) -> None:
        path = urlparse.urlparse(self.path).path
        if not path.startswith("/media/"):
            self._json(404, {"error": {"code": "not_found"}})
            return
        token = path[len("/media/"):]
        entry = TOKENS.get(token)
        if entry is None:
            self._json(404, {"error": {"code": "expired"}})
            return

        headers = dict(entry["headers"])
        range_header = self.headers.get("Range")
        if range_header:
            headers["Range"] = range_header
        request = urlrequest.Request(entry["url"], headers=headers)
        try:
            upstream = urlrequest.urlopen(request, timeout=45)
        except urlerror.HTTPError as error:
            status = error.code
            self.send_response(status)
            for name in ("Content-Range", "Content-Length", "Content-Type"):
                value = error.headers.get(name)
                if value:
                    self.send_header(name, value)
            self.end_headers()
            if not head_only:
                shutil.copyfileobj(error, self.wfile, 64 * 1024)
            return
        except Exception as error:  # noqa: BLE001
            self._json(502, {"error": {"code": "stream_failed", "message": str(error)}})
            return

        with upstream:
            self.send_response(upstream.status)
            for name in ("Content-Type", "Content-Length", "Content-Range"):
                value = upstream.headers.get(name)
                if value:
                    self.send_header(name, value)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header(
                "Content-Disposition",
                f'attachment; filename="{entry["filename"]}"',
            )
            self.end_headers()
            if not head_only:
                shutil.copyfileobj(upstream, self.wfile, 64 * 1024)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(
        f"maiDL resolver listening on http://{args.host}:{args.port}\n"
        f"Use http://<this-machine-LAN-IP>:{args.port} in maiDL → Settings → Social links.",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
