from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from html import escape
from pathlib import Path
import sys

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        mime = "text/html; charset=utf-8"
        if self.path.endswith("/control.js"):
            body, mime = "window.controlRequestLoaded = true;", "application/javascript"
        elif self.path.endswith("/should-cancel.js"):
            body, mime = "window.candidateRequestLoaded = true;", "application/javascript"
        elif self.path.startswith("/native-fixture-"):
            path = escape(self.path, quote=True)
            body = ("<!doctype html><title>Owned loopback page</title>"
                    f"<script src='{path}/control.js'></script>"
                    f"<script src='{path}/should-cancel.js'></script>")
        else:
            body = "<!doctype html><title>Owned loopback page</title>" if self.path == "/" else "owned:" + self.path
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
