"""Disposable loopback-only website for WebKit profile integration checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
import sys

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/favicon.ico'):
            self.send_response(204); self.end_headers(); return
        body = b'<!doctype html><html><head><title>Alcove profile fixture</title></head><body><p>Disposable profile test.</p><script>window.alcoveFixtureReady=true;</script></body></html>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *args):
        pass

class FixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        # The fixture is loopback-only; avoid a hostname/reverse-DNS lookup at startup.
        TCPServer.server_bind(self)
        self.server_name = '127.0.0.1'
        self.server_port = self.server_address[1]

server = FixtureServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port), encoding='ascii')
server.serve_forever()
