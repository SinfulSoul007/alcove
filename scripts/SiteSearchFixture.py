"""Owned loopback-only endpoints for site-search request/account checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import html
import json
import sys
import threading

class Handler(BaseHTTPRequestHandler):
    counts = {}
    lock = threading.Lock()
    def do_GET(self):
        parts = urlsplit(self.path)
        if parts.path == '/__count':
            target = parse_qs(parts.query).get('path', ['/search'])[0]
            with self.lock:
                count = sum(self.counts.values()) if target == '*' else self.counts.get(target, 0)
            body = json.dumps({'count': count}).encode()
            content_type = 'application/json'
        elif parts.path == '/favicon.ico':
            self.send_response(204); self.end_headers(); return
        elif parts.path == '/osd-redirect':
            with self.lock:
                self.counts[parts.path] = self.counts.get(parts.path, 0) + 1
            self.send_response(302)
            self.send_header('Location', '/opensearch.xml')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        elif parts.path == '/opensearch.xml':
            with self.lock:
                self.counts[parts.path] = self.counts.get(parts.path, 0) + 1
            name = 'Leaked request metadata' if self.headers.get('Cookie') or self.headers.get('Referer') else 'Owned search'
            body = (f'<?xml version="1.0"?><OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">'
                    f'<ShortName>{name}</ShortName><Description>Owned fixture</Description>'
                    '<Url type="application/json" rel="suggestions" template="/never?q={searchTerms}" />'
                    '<Url type="text/html" template="/search?q={searchTerms}&amp;kind=advertised" />'
                    '</OpenSearchDescription>').encode()
            content_type = 'application/opensearchdescription+xml'
        else:
            with self.lock:
                self.counts[parts.path] = self.counts.get(parts.path, 0) + 1
            payload = json.dumps({'query': parse_qs(parts.query, keep_blank_values=True), 'cookie': self.headers.get('Cookie', ''), 'path': parts.path})
            advertised = ('<base href="https://example.invalid/">'
                          '<link rel="search" type="application/opensearchdescription+xml" href="https://example.invalid/foreign.xml">'
                          '<link id="owned-search" rel="search" type="application/opensearchdescription+xml" href="/opensearch.xml">') if parts.path == '/discover' else ''
            body = ('<!doctype html><html><head><title>Alcove site search fixture</title>' + advertised + '</head><body><pre id="result">' + html.escape(payload) + '</pre><script>window.alcoveSiteSearchReady=true;</script></body></html>').encode()
            content_type = 'text/html; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *args):
        pass

class Server(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = '127.0.0.1'
        self.server_port = self.server_address[1]

server = Server(('127.0.0.1', 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port), encoding='ascii')
server.serve_forever()
