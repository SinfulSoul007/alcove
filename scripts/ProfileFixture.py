"""Disposable loopback-only website for WebKit profile integration checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
import sys
import json
import threading
from urllib.parse import urlsplit, parse_qs

class Handler(BaseHTTPRequestHandler):
    counts = {}
    count_lock = threading.Lock()
    def do_GET(self):
        parts = urlsplit(self.path)
        if parts.path == '/__count':
            target = parse_qs(parts.query).get('path', [''])[0]
            with self.count_lock:
                count = self.counts.get(target, 0)
            body = json.dumps({'count': count}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith('/favicon.ico'):
            self.send_response(204); self.end_headers(); return
        with self.count_lock:
            self.counts[self.path] = self.counts.get(self.path, 0) + 1
            count = self.counts[self.path]
        if parts.path == '/redirect':
            self.send_response(302); self.send_header('Location', '/?' + parts.query)
            self.end_headers(); return
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
