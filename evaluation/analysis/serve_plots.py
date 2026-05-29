#!/usr/bin/env python3
"""
Serve plots.html with a save endpoint so in-browser text edits persist.

- GET  /plots.html (and other files) -> served from this directory (like http.server)
- POST /save-overrides  {id: html, ...} -> written to plots_overrides.json

plot.py reads plots_overrides.json on regeneration and re-applies the saved text,
so manual edits survive re-running plot.py.

Run:  python serve_plots.py [port]   (default 8077, binds 127.0.0.1)
"""
import json
import os
import sys
from http.server import SimpleHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
OVERRIDES = os.path.join(HERE, "plots_overrides.json")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8077


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=HERE, **k)

    def do_POST(self):
        if self.path != "/save-overrides":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(payload, dict):
                raise ValueError("expected object")
        except (ValueError, json.JSONDecodeError) as e:
            self.send_error(400, f"bad payload: {e}")
            return
        # merge with any existing overrides
        existing = {}
        if os.path.exists(OVERRIDES):
            try:
                existing = json.load(open(OVERRIDES))
            except json.JSONDecodeError:
                existing = {}
        existing.update(payload)
        with open(OVERRIDES, "w") as f:
            json.dump(existing, f, indent=2, ensure_ascii=False)
        body = json.dumps({"ok": True, "saved": len(payload)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass  # quiet


if __name__ == "__main__":
    print(f"Serving {HERE} at http://localhost:{PORT}/plots.html")
    print(f"Saving edits to {OVERRIDES}")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
