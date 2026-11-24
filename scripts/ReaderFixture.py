#!/usr/bin/env python3
"""Owned loopback-only articles; never contacts an external website."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, sys
prose = ('A patient reader follows the river through the mountains. This detailed report explains the landscape, its history, and the people who live here. ' * 30)
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/short'):
            body = '<p>There is no article here.</p><input id="draft">'
        else:
            body = '<nav>CHROME_NAVIGATION <a href="/account">Account</a></nav><article><h1>The River Report</h1><p>' + prose + '</p><h2>Along the valley</h2><p>' + prose + '</p><blockquote>Evidence matters.</blockquote><p><strong>Evidence</strong> and <a href="/next">further reading</a>.</p></article><form><input id="draft" value="original"></form>'
        html = ('<!doctype html><html><head><meta charset="utf-8"><title>The River Report</title></head><body>' + body + '</body></html>').encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(html))); self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(html)
    def log_message(self, *_): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
