from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json,sys,threading
from urllib.parse import urlsplit,parse_qs
from pathlib import Path
requests=[]
lock=threading.Lock()
allowed={'safe.alcove.example','listed.alcove.example'}
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_CONNECT(self):
        host,port=self.path.rsplit(':',1)
        if host not in allowed or port!='80':self.send_error(403);return
        self.send_response(200,'Connection Established');self.end_headers()
        self.close_connection=False
    def do_POST(self):self.handle_owned()
    def do_GET(self):self.handle_owned()
    def handle_owned(self):
        parsed=urlsplit(self.path)
        host=parsed.hostname or self.headers.get('Host','').split(':')[0]
        query=parse_qs(parsed.query)
        if host=='127.0.0.1' and parsed.path=='/_events':
            with lock:body=json.dumps(requests).encode()
            self.respond(200,body,'application/json');return
        if host not in allowed:self.send_error(403);return
        size=int(self.headers.get('Content-Length','0'))
        if size>65536:self.send_error(413);return
        body=self.rfile.read(size).decode('utf-8')
        event={'host':host,'path':parsed.path,'method':self.command,'case':query.get('case',[''])[0],'body':body}
        with lock:requests.append(event)
        print('OWNED_NAVIGATION_REQUEST '+json.dumps(event),flush=True)
        case=query.get('case',[''])[0]
        if parsed.path.startswith('/redirect'):
            status=307 if parsed.path=='/redirect307' else 302
            target='file' if parsed.path=='/redirect-download' else 'target'
            self.respond(status,b'','text/plain',{'Location':'http://listed.alcove.example/'+target+'?case='+case});return
        if parsed.path=='/file':
            self.respond(200,b'owned download fixture','application/octet-stream',{'Content-Disposition':'attachment; filename="owned.txt"'});return
        if parsed.path=='/frame':
            body=('<!doctype html><title>Owned parent</title><iframe src="http://listed.alcove.example/target?case='+case+'"></iframe>').encode()
        else:
            body=b'<!doctype html><title>Owned navigation</title><form id="f" method="post"><input id="token" name="token" value="keep-owned"></form>'
        self.respond(200,body,'text/html')
    def respond(self,status,body,kind,headers=None):
        self.send_response(status)
        self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        for name,value in (headers or {}).items():self.send_header(name,value)
        self.end_headers()
        self.wfile.write(body)
class Server(ThreadingHTTPServer):daemon_threads=True
server=Server(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
print('OWNED_PROXY_READY '+str(server.server_port),flush=True)
server.serve_forever()
