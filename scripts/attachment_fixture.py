"""Loopback-only gateway for synthetic Android attachment checks.

Accepts only the generated test PNG, never sends a task or connects to a coding
client. Seed --image-output into the isolated emulator's Pictures directory.
"""

import argparse
from http.server import ThreadingHTTPServer
from pathlib import Path
import struct
from urllib.parse import parse_qs, urlsplit
import uuid
import zlib

import notification_fixture as fixture


def synthetic_image():
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    width, height = 600, 400
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            if 80 < x < 520 and 70 < y < 330:
                color = (242, 178, 137) if (x // 40 + y // 40) % 2 else (139, 217, 190)
            else:
                color = (23, 108, 96)
            rows.extend(color)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


IMAGE = synthetic_image()
UPLOADS = {}
UPLOAD_PATH = f"/api/sessions/{fixture.SID}/uploads"
fixture.SESSION.update({
    "title": "Synthetic attachment check", "cwd": "/synthetic/attachments",
    "access": {"canSend": True},
})
fixture.STATS.update({"accepted_uploads": 0, "preview_reads": 0})


class Handler(fixture.Handler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path.startswith(UPLOAD_PATH + "/") and path.endswith("/preview"):
            upload_id = path[len(UPLOAD_PATH) + 1:-len("/preview")]
            with fixture.LOCK:
                image = UPLOADS.get(upload_id)
                fixture.STATS["preview_reads"] += 1
            if image is None:
                self.reply({"error": "Unknown synthetic upload"}, 404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(image)))
            self.end_headers()
            try:
                self.wfile.write(image)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            return
        super().do_GET()

    def do_POST(self):
        parsed = urlsplit(self.path)
        if parsed.path != UPLOAD_PATH:
            super().do_POST()
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length != len(IMAGE):
            self.reply({"error": "Only the generated synthetic PNG is accepted"}, 400)
            return
        query = parse_qs(parsed.query)
        upload_id = query.get("id", [""])[0]
        try:
            uuid.UUID(upload_id)
        except ValueError:
            self.reply({"error": "Invalid synthetic upload id"}, 400)
            return
        body = self.rfile.read(length)
        if body != IMAGE:
            self.reply({"error": "Only the generated synthetic PNG is accepted"}, 400)
            return
        with fixture.LOCK:
            UPLOADS[upload_id] = body
            fixture.STATS["accepted_uploads"] += 1
        self.reply({"id": upload_id})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18767)
    parser.add_argument("--image-output", type=Path, required=True)
    args = parser.parse_args()
    args.image_output.write_bytes(IMAGE)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Synthetic attachment fixture: http://127.0.0.1:{server.server_port}", flush=True)
    print(f"Generated test PNG: {args.image_output}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
