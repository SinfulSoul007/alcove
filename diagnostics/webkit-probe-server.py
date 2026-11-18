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
        if request.path.startswith("/link-policy/") and request.path.endswith("/source"):
            directory = escape(request.path.rsplit("/", 1)[0], quote=True)
            body = ("<!doctype html><title>Owned hyperlink fixture</title>"
                    f"<a id='destination' href='{directory}/destination' ping='{directory}/ping'>Open</a>")
        elif request.path.startswith("/rule-cache/"):
            if request.path.endswith("/candidate.js"):
                self.respond("window.cacheFixtureScriptRan = true;", "application/javascript", "public, max-age=600")
                return
            directory = escape(request.path.rsplit("/", 1)[0], quote=True)
            body = ("<!doctype html><title>Owned cache fixture</title>"
                    f"<script src='{directory}/candidate.js'></script>")
        elif request.path.endswith("/control.js"):
            body, mime = "window.controlRequestLoaded = true;", "application/javascript"
        elif request.path.endswith("/should-cancel.js"):
            body, mime = "window.candidateRequestLoaded = true;", "application/javascript"
        elif request.path.startswith("/native-fixture-"):
            path = escape(request.path, quote=True)
            body = ("<!doctype html><title>Owned loopback page</title>"
                    f"<script src='{path}/control.js'></script>"
                    f"<script src='{path}/should-cancel.js'></script>")
        else:
            body = "<!doctype html><title>Owned loopback page</title>"
        self.respond(body, mime)

    def do_POST(self):
        path = urlsplit(self.path).path
        if not path.startswith("/link-policy/") or not path.endswith(("/ping", "/beacon")):
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if size > 1024:
            self.send_error(413)
            return
        self.rfile.read(size)
        with self.lock:
            self.counts[path] = self.counts.get(path, 0) + 1
        self.respond("", "text/plain; charset=utf-8")

    def respond(self, body, mime, cache_control="no-store"):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Cache-Control", cache_control)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
    Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
