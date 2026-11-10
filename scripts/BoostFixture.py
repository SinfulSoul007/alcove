import http.server
import pathlib
import sys
import time


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/slow.js':
            time.sleep(1.0)
            body = b"window.slowFinished=true;"
            mime = 'text/javascript'
        elif self.path == '/fixture.js':
            body = b"""window.siteGlobal=17; window.addEventListener('message',e=>{if(e.data.kind==='frameColor')window.frameColor=e.data.color;});
            if(location.pathname==='/review'){
              const sheet=new CSSStyleSheet();sheet.replaceSync('@layer site {#ad{display:block!important}} html{font-size:24px} #fixed{font-size:13px}');document.adoptedStyleSheets=[sheet];
              window.captureCount=0;
              for(const type of ['pointerdown','mousedown','pointerup','mouseup','click','dblclick','contextmenu','touchstart','touchend'])
                for(const node of [window,document]) node.addEventListener(type,()=>{window.captureCount++;const input=document.getElementById('keep');if(input)input.value='page activated';},true);
            }"""
            mime = 'text/javascript'
        elif self.path == '/frame.js':
            body = b"parent.postMessage({kind:'frameColor',color:getComputedStyle(document.getElementById('child')).color},'*');"
            mime = 'text/javascript'
        elif self.path == '/frame':
            body = b"<!doctype html><p id='child'>Unmodified frame</p><script src='/frame.js'></script>"
            mime = 'text/html'
        else:
            port = self.server.server_address[1]
            body = ("<!doctype html><html><head><title>Owned Boost fixture</title><script src='/fixture.js'></script></head><body>"
                    "<p id='target'>Original target</p><p id='fixed'>Fixed text</p><form><input id='keep' value='original'></form>"
                    "<a id='ad' href='/clicked'>Hide this link</a><div id='second'>Another element</div>"
                    f"<iframe src='http://localhost:{port}/frame'></iframe>"
                    "<p>" + "Owned content " * 1000 + "</p>" + ("<script src='/slow.js'></script>" if self.path == '/slow' else "") + "</body></html>").encode()
            mime = 'text/html'
        self.send_response(200)
        self.send_header('Content-Type', mime + '; charset=utf-8')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'none'; frame-src http://localhost:" + str(self.server.server_address[1]))
        self.send_header('Cache-Control', 'max-age=60')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
