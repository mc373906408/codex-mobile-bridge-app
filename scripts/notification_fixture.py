"""Loopback-only synthetic gateway for Android notification device checks.

Never connect this fixture to a real coding client. POST /__fixture/event injects
synthetic activity; every application write endpoint is rejected and counted.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
from urllib.parse import urlsplit
import uuid

SID = "11111111-1111-4111-8111-111111111111"
SESSION = {
    "id": SID, "host": "local", "title": "Synthetic notification check",
    "cwd": "/synthetic/notifications", "status": "idle", "connected": True,
    "source": "local", "draftAccountIdentity": "synthetic-account",
    "access": {}, "requests": [],
}
LOCK = threading.Lock()
EVENTS = []
STATS = {"auth_reads": 0, "event_reads": 0, "application_writes": 0}
STREAM = "synthetic-notification-stream"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, value, status=200):
        payload = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/api/auth":
            with LOCK:
                STATS["auth_reads"] += 1
            self.reply({"authenticated": True, "passwordless": True,
                        "csrf": "synthetic-csrf", "draftIdentity": "synthetic-gateway",
                        "notifications": True, "transport": "poll",
                        "computer": {"name": "Notification fixture", "platform": "Synthetic"}})
        elif path == "/api/clients":
            self.reply({"clients": [{"id": "codex", "enabled": True, "connected": True}]})
        elif path == "/api/codex/entries":
            self.reply({"entries": []})
        elif path == "/api/sessions":
            self.reply({"sessions": [SESSION]})
        elif path.endswith("/timeline"):
            self.reply({"epoch": "synthetic-epoch", "sequence": 1, "before": None,
                        "hasMore": False, "meta": SESSION,
                        "rows": [{"key": "result", "role": "assistant",
                                  "text": "Synthetic read-only task result. No real task was submitted."}]})
        elif path.endswith("/poll"):
            time.sleep(1)
            self.reply({"state": None})
        elif path == "/api/mobile/events":
            with LOCK:
                STATS["event_reads"] += 1
                value = {"streamId": STREAM, "cursor": len(EVENTS), "events": list(EVENTS)}
            self.reply(value)
        elif path == "/__fixture/state":
            with LOCK:
                value = {**STATS, "events": len(EVENTS), "stream": STREAM}
            self.reply(value)
        else:
            self.reply({"error": "Unknown synthetic route"}, 404)

    def do_POST(self):
        path = urlsplit(self.path).path
        if path != "/__fixture/event":
            with LOCK:
                STATS["application_writes"] += 1
            self.reply({"error": "Synthetic fixture never controls a real client"}, 405)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 1024:
            self.reply({"error": "Fixture input too large"}, 413)
            return
        try:
            value = json.loads(self.rfile.read(length) or b"{}")
            kind = value.get("kind", "completion")
            if kind not in ("completion", "request"):
                raise ValueError("Unknown event kind")
        except (ValueError, AttributeError):
            self.reply({"error": "Invalid fixture event"}, 400)
            return
        with LOCK:
            event = {"id": uuid.uuid4().hex, "sequence": len(EVENTS) + 1,
                     "threadId": SID, "host": "local", "kind": kind,
                     "createdAt": time.time(), "title": "PRIVATE_TITLE_MUST_NOT_NOTIFY",
                     "body": "PRIVATE_BODY_MUST_NOT_NOTIFY"}
            EVENTS.append(event)
            del EVENTS[:-200]
        self.reply({"eventId": event["id"], "kind": kind})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18766)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Synthetic notification fixture: http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
