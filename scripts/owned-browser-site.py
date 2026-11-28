import faulthandler,time
print("OWNED_SITE_START",time.monotonic(),flush=True)
faulthandler.dump_traceback_later(8)
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from pathlib import Path
import argparse,json
p=argparse.ArgumentParser();p.add_argument("--ready-file",type=Path,required=True);a=p.parse_args()
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  names={"/one":"one","/two":"two"}
  if self.path not in names:
   self.send_error(404);return
  name=names[self.path]
  body=(f"<!doctype html><html><head><meta charset='utf-8'><title>Alcove owned page {name}</title></head><body style='font:24px system-ui;padding:48px;background:#f2f7f3;color:#153c2c'><h1>Alcove owned page {name}</h1><p>Actual HTTP and WebKit rendering in the ordinary installed app.</p><a href='/two'>Open page two</a></body></html>").encode()
  self.send_response(200);self.send_header("Content-Type","text/html; charset=utf-8");self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body)
class OwnedLoopbackServer(ThreadingHTTPServer):
 def server_bind(self):
  # This fixture has a known local name; do not perform reverse DNS at startup.
  TCPServer.server_bind(self)
  self.server_name="localhost"
  self.server_port=self.server_address[1]
print("OWNED_SITE_BIND",time.monotonic(),flush=True)
server=OwnedLoopbackServer(("127.0.0.1",0),Handler)
a.ready_file.write_text(json.dumps({"url":f"http://127.0.0.1:{server.server_port}"}))
print("OWNED_SITE_READY",server.server_port,time.monotonic(),flush=True)
faulthandler.cancel_dump_traceback_later()
server.serve_forever()
