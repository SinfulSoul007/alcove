from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from html import escape
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlsplit
import sys

class Fixture(BaseHTTPRequestHandler):
    counts = {}
    lock = Lock()

    def do_GET(self):
        request = urlsplit(self.path)
        if request.path == "/__request_count":
            target = parse_qs(request.query).get("path", [""])[0]
            with self.lock:
                count = self.counts.get(target, 0)
            self.respond(str(count), "text/plain; charset=utf-8")
            return
        with self.lock:
            self.counts[request.path] = self.counts.get(request.path, 0) + 1

        mime = "text/html; charset=utf-8"
        if request.path.endswith("/control.js"):
            body, mime = "window.controlRequestLoaded = true;", "application/javascript"
        elif request.path.endswith("/should-cancel.js"):
            body, mime = "window.candidateRequestLoaded = true;", "application/javascript"
        elif request.path.startswith("/native-fixture-"):
            path = escape(request.path, quote=True)
            body = ("<!doctype html><title>Owned loopback page</title>"
                    "<div id='alcove-owned-sponsored'>Owned sponsored fixture</div>"
                    f"<script src='{path}/control.js'></script>"
                    f"<script src='{path}/should-cancel.js'></script>")
        else:
            body = "<!doctype html><title>Owned loopback page</title>"
        self.respond(body, mime)

    def respond(self, body, mime):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
    Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
