#!/usr/bin/python3
"""
Harbor native messaging host (Chrome-family + Firefox), bundled in Harbor.app.
Receives a URL from the browser and opens it with Harbor via harbor://download.
Protocol: 4-byte length (native byte order) + UTF-8 JSON.
"""
import json
import struct
import subprocess
import sys
from urllib.parse import quote, urlparse

MAX_IN = 1024 * 1024
# Firefox passes the manifest path / add-on id, Chrome passes chrome-extension://...
HOST_NAME = "com.harbor.firefox" if any(
    ("firefox" in a.lower() or "mozilla" in a.lower()) for a in sys.argv[1:]
) else "com.harbor.chrome"


def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = sys.stdin.buffer.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_msg():
    header = read_exact(4)
    if header is None:
        return None
    length = struct.unpack("=I", header)[0]
    if length > MAX_IN:
        raise ValueError("Message too large")
    body = read_exact(length)
    if body is None:
        raise ValueError("Incomplete message")
    return json.loads(body.decode("utf-8"))


def write_msg(obj):
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("=I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def usable_url(value):
    if not isinstance(value, str) or not value:
        return ""
    p = urlparse(value)
    return value if p.scheme in ("http", "https") and p.netloc else ""


def scheme_url(url, referrer):
    out = "harbor://download?url=" + quote(url, safe="")
    ref = usable_url(referrer)
    if ref:
        out += "&referrer=" + quote(ref, safe="")
    return out


def handle(msg):
    if not isinstance(msg, dict):
        return {"ok": False, "error": "Expected a JSON object."}
    action = msg.get("action") or "download"
    if action == "ping":
        return {"ok": True, "host": HOST_NAME}
    if action != "download":
        return {"ok": False, "error": "Unknown action."}
    url = usable_url(msg.get("url"))
    if not url:
        return {"ok": False, "error": "Only valid HTTP/HTTPS URLs are accepted."}
    try:
        r = subprocess.run(
            ["/usr/bin/open", scheme_url(url, msg.get("referrer"))],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=12, check=False,
        )
    except Exception as exc:
        return {"ok": False, "error": "Could not open Harbor: " + str(exc)[:150]}
    if r.returncode == 0:
        return {"ok": True}
    detail = (r.stderr or "").strip()[:180]
    return {"ok": False, "error": "Could not open Harbor. Is it installed?" + ((" " + detail) if detail else "")}


def main():
    while True:
        try:
            msg = read_msg()
            if msg is None:
                return
            write_msg(handle(msg))
        except Exception as exc:
            try:
                write_msg({"ok": False, "error": str(exc)[:280]})
            except Exception:
                return


if __name__ == "__main__":
    main()
