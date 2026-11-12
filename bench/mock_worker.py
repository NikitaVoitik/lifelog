"""A stand-in for the Cloudflare Worker that bench/pipeline.sh points `lifelog sync` at: accepts every upload,
returns empty pulls, and counts requests and bytes into $MOCK_STATS (JSON). Usage: mock_worker.py PORT STATS_FILE"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, STATS = int(sys.argv[1]), sys.argv[2]
stats = {"requests": 0, "bytes_in": 0, "by_path": {}}


def note(path: str, n: int) -> None:
    key = "/".join(path.split("?")[0].split("/")[:3])
    stats["requests"] += 1
    stats["bytes_in"] += n
    s = stats["by_path"].setdefault(key, {"requests": 0, "bytes": 0})
    s["requests"] += 1
    s["bytes"] += n
    with open(STATS, "w") as f:
        json.dump(stats, f)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def body(self) -> int:
        n = int(self.headers.get("content-length") or 0)
        left = n
        while left:
            left -= len(self.rfile.read(min(left, 1 << 20)))
        return n

    def do_PUT(self):
        n = self.body()
        note(self.path, n)
        self.reply({"size": n})

    def do_POST(self):
        n = self.body()
        note(self.path, n)
        self.reply({"ok": True})

    def do_GET(self):
        note(self.path, 0)
        self.reply({"events": [], "runs": [], "summaries": [], "more": False})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
