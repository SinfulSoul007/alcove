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
};
window.makePassThrough=()=>{
    let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j;});
    Object.defineProperty(promise,'constructor',{value:Promise});
    window.settlePassThrough=()=>{if(mode.endsWith('-error'))reject('owned');else resolve('owned');};
    return promise;
};
window.observePassThrough=next=>{
    window.ownedPassThroughParentPromise=Object.getPrototypeOf(next)===Promise.prototype;
    next.then(value=>{window.ownedPassThroughObserved=value;},error=>{window.ownedPassThroughObserved=error;});
    document.querySelector('iframe')?.remove();
    setTimeout(settlePassThrough,100);
    setTimeout(()=>{window.ownedPassThroughFinished=true;},250);
};
window.consume=async promise=>{
    if(mode==='all')await Promise.all([promise]);else await promise;
    move(mode);
};
if(mode==='same')new Promise(resolve=>setTimeout(resolve,10)).then(()=>move(mode));
else document.addEventListener('DOMContentLoaded',()=>{
    if(mode==='detached')setTimeout(()=>{window.ownedDetachedFinished=true;},250);
    if(mode.startsWith('closed-'))window.open('background.html','owned-closing-realm');
    else {const frame=document.createElement('iframe');frame.src='background.html';document.body.append(frame);}
});
</script><body>Owned options page</body>'''
BACKGROUND = b'''<!doctype html><title>Owned background realm</title><script>
if(location.hash===''){
    const ownerWindow=opener||parent;
    const mode=ownerWindow.mode;
    if(mode==='sync')parent.move(mode);
    else if(mode==='detached'){const owner=parent;owner.registerDetached(()=>{owner.ownedDetachedRan=true;try{owner.move(owner.document.querySelector('iframe')===null ? mode:'detached-not-removed');}catch(error){owner.ownedDetachedError=error.name;}});}
    else if(mode.startsWith('empty-')||mode.startsWith('closed-')){
        const owner=ownerWindow,promise=owner.makePassThrough();
        const next=Reflect.apply(Promise.prototype.then,promise,[]);
        owner.observePassThrough(next);
        if(mode.startsWith('closed-'))window.close();
    }
    else {
        const settled=mode==='settled'||mode==='revoked-settled';
        const promise=settled?Promise.resolve('owned'):new Promise((resolve,reject)=>setTimeout(()=>mode==='reject'?reject('owned'):resolve('owned'),10));
        if(mode==='then'||mode==='settled')promise.then(parent.resumeThen);
        else if(mode==='bound')promise.then(parent.resumeThen.bind(null));
        else if(mode==='proxy')promise.then(new Proxy(parent.resumeThen,{}));
        else if(mode.startsWith('finally-')){
            if(mode.endsWith('-generic'))Object.defineProperty(promise,'then',{value:function(a,b){return Reflect.apply(Promise.prototype.then,this,[a,b]);}});
            if(mode.startsWith('finally-parent-'))Reflect.apply(parent.Promise.prototype.finally,promise,[parent.resumeThen]);
            else promise.finally(parent.resumeThen);
        }else if(mode==='reject')promise.catch(parent.resumeThen);
        else if(mode.startsWith('revoked')){
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
