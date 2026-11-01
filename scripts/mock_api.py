#!/usr/bin/env python3
"""Minimal stand-in for the HappiE API, used by CI screenshots.

Serves a fixed family library on 127.0.0.1:18080 (the app's default API
URL) so the simulator renders real screens without the backend. Pass a
sample MP4 path to make playback work; byte ranges are supported because
AVPlayer requires them for progressive MP4.
"""

import json
import os
import re
import struct
import sys
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("MOCK_API_PORT", "18080"))
BASE = f"http://localhost:{PORT}"
SAMPLE_MP4 = sys.argv[1] if len(sys.argv) > 1 else None

CHILDREN = [
    {"id": "c0000000-0000-4000-8000-000000000001", "name": "Mia"},
    {"id": "c0000000-0000-4000-8000-000000000002", "name": "Leo"},
    {"id": "c0000000-0000-4000-8000-000000000003", "name": "Ava"},
]

TITLES = [
    ("Bluey Builds a Blanket Fort", 412),
    ("Counting Stars with Grandma", 185),
    ("The Big Red Fire Truck", 1264),
    ("Ocean Animals for Little Explorers", 3725),
    ("Bedtime Songs", 96),
    ("Making Pancakes Together", 540),
    ("A Day at the Zoo", 801),
    ("Learning Colours with Paint", 333),
]

COLOURS = [
    (0x2E, 0x86, 0xDE), (0xF3, 0x9C, 0x12), (0xE7, 0x4C, 0x3C), (0x16, 0xA0, 0x85),
    (0x8E, 0x44, 0xAD), (0xD3, 0x54, 0x00), (0x27, 0xAE, 0x60), (0xC0, 0x39, 0x2B),
]


def video_id(index):
    return f"a0000000-0000-4000-8000-{index:012d}"


def png(width, height, rgb):
    """Solid-colour PNG with a lighter lower band, no third-party deps."""
    light = tuple(min(255, c + 60) for c in rgb)
    rows = b"".join(
        b"\x00" + bytes(light if y > height * 0.62 else rgb) * width for y in range(height)
    )

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


def manifest_video(index):
    title, duration = TITLES[index]
    return {
        "id": video_id(index),
        "title": title,
        "description": "",
        "duration_seconds": duration,
        "download_priority": "normal",
        "expires_at": None,
        "assets": [
            {
                "id": str(uuid.UUID(int=index + 1)),
                "kind": "thumbnail",
                "version": 1,
                "url": f"{BASE}/thumbs/{index}.png",
            },
            {
                "id": str(uuid.UUID(int=index + 101)),
                "kind": "mp4",
                "quality": "720p",
                "width": 1280,
                "height": 720,
                "duration_seconds": duration,
                "file_size_bytes": 1_000_000,
                "version": 1,
                "url": f"{BASE}/media/sample.mp4",
            },
        ],
    }


def child_profile(child):
    return {**child, "avatar_color": None, "birth_year": 2020, "storage_quota_mb": 8192}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("mock-api: " + fmt % args + "\n")

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/children":
            return self.send_json([child_profile(c) for c in CHILDREN])
        if match := re.fullmatch(r"/thumbs/(\d+)\.png", path):
            body = png(320, 180, COLOURS[int(match.group(1)) % len(COLOURS)])
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if re.fullmatch(r"/videos/[0-9a-fA-F-]+/playback-url", path):
            return self.send_json({"url": f"{BASE}/media/sample.mp4", "expires_in_seconds": 3600})
        if path == "/media/sample.mp4" and SAMPLE_MP4 and os.path.exists(SAMPLE_MP4):
            return self.send_media()
        return self.send_json({"error": "not found"}, status=404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if path == "/devices/register":
            child_id = body.get("child_profile_id", CHILDREN[0]["id"])
            return self.send_json(
                {"id": "d0000000-0000-4000-8000-000000000001", "child_profile_id": child_id, "storage_quota_mb": 8192}
            )
        if match := re.fullmatch(r"/devices/([0-9a-fA-F-]+)/sync", path):
            return self.send_json(
                {
                    "device_id": match.group(1),
                    "child_profile_id": CHILDREN[0]["id"],
                    "storage_quota_mb": 8192,
                    "expires_at": "2099-01-01T00:00:00Z",
                    "videos": [manifest_video(i) for i in range(len(TITLES))],
                    "remove": [],
                }
            )
        if path == "/watch-progress":
            return self.send_json({"ok": True})
        return self.send_json({"error": "not found"}, status=404)

    def send_media(self):
        size = os.path.getsize(SAMPLE_MP4)
        start, end = 0, size - 1
        status = 200
        if header := self.headers.get("Range"):
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
            first, last = (match.group(1), match.group(2)) if match else ("", "")
            if first:
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            elif last:
                start = max(0, size - int(last))  # suffix range: final N bytes
            if not (first or last) or start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                return self.end_headers()
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(SAMPLE_MP4, "rb") as media:
            media.seek(start)
            self.wfile.write(media.read(end - start + 1))


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
