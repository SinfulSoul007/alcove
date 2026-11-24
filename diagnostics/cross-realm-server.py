from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
OPTIONS = b'''<!doctype html><title>Owned options realm</title><script>
const mode=new URL(location.href).searchParams.get('mode');
window.mode=mode;
window.move=label=>self.location.replace('#'+label);
window.resumeThen=()=>move(mode);
window.registerDetached=callback=>{
    let resolve;const promise=new Promise(r=>{resolve=r;});promise.then(callback);
    document.querySelector('iframe').remove();resolve('owned');
    setTimeout(()=>{window.ownedDetachedFinished=true;},50);
};
window.consume=async promise=>{
    if(mode==='all')await Promise.all([promise]);else await promise;
    move(mode);
};
if(mode==='same')new Promise(resolve=>setTimeout(resolve,10)).then(()=>move(mode));
else document.addEventListener('DOMContentLoaded',()=>{
    const frame=document.createElement('iframe');frame.src='background.html';document.body.append(frame);
});
</script><body>Owned options page</body>'''
BACKGROUND = b'''<!doctype html><title>Owned background realm</title><script>
if(location.hash===''){
    const mode=parent.mode;
    if(mode==='sync')parent.move(mode);
    else if(mode==='detached'){const owner=parent;owner.registerDetached(()=>{owner.ownedDetachedRan=true;});}
    else {
        const promise=mode==='settled'?Promise.resolve('owned'):new Promise((resolve,reject)=>setTimeout(()=>mode==='reject'?reject('owned'):resolve('owned'),10));
        if(mode==='then'||mode==='settled')promise.then(parent.resumeThen);
        else if(mode==='bound')promise.then(parent.resumeThen.bind(null));
        else if(mode==='proxy')promise.then(new Proxy(parent.resumeThen,{}));
        else if(mode==='finally')promise.finally(parent.resumeThen);
        else if(mode==='reject')promise.catch(parent.resumeThen);
        else if(mode==='revoked'){
            const record=Proxy.revocable(parent.resumeThen,{});record.revoke();
            try {
                const next=promise.then(record.proxy);parent.ownedRegistrationReturned=true;
                next.catch(error=>{parent.ownedRejection=error.name;});
            }catch(error){parent.ownedSyncError=true;}
        }else parent.consume(promise);
    }
}
</script><body>Owned child page</body>'''
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=OPTIONS if self.path.split('?')[0]=='/options.html' else BACKGROUND
        self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
with ThreadingHTTPServer(('127.0.0.1',0),Handler) as server:
    Path(sys.argv[1]).write_text(str(server.server_port));server.serve_forever()
