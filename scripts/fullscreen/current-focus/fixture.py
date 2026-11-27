from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import sys
body=Path(__file__).with_name('page.html').read_bytes()
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path!='/page-no-media':self.send_error(404);return
  self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers()
  try:self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError):pass
 def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
Path(sys.argv[1]).write_text(str(server.server_port));server.serve_forever()
