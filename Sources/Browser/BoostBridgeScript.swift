import Foundation

enum BoostBridgeScript {
    static let page = #"""
    /* Alcove Boost page bootstrap v1 — contains no profile definitions. */
    (()=>{
      const key='__alcoveBoostPageNonce_v1';
      if(Object.getOwnPropertyDescriptor(globalThis,key)) return;
      const bytes=crypto.getRandomValues(new Uint8Array(16));
      const nonce=Array.from(bytes,x=>x.toString(16).padStart(2,'0')).join('');
      Object.defineProperty(globalThis,key,{value:nonce,writable:false,configurable:false});
    })();
    """#
    static let isolated = #"""
    /* Alcove Boost isolated bridge v1 — contains no profile definitions. */
    (()=>{
      if(globalThis.__alcoveBoostState_v1) return;
      const nonce=Array.from(crypto.getRandomValues(new Uint8Array(16)),x=>x.toString(16).padStart(2,'0')).join('');
      const state={nonce,ready:false,sheets:[],serial:0,picker:null,ran:new Set(),pendingPick:null};
      Object.defineProperty(globalThis,'__alcoveBoostState_v1',{value:state});
      const valid=(n,h)=>n===nonce && (location.protocol==='http:'||location.protocol==='https:') && (location.hostname===h||location.hostname===h+'.');
      const post=(kind,extra={})=>webkit.messageHandlers.alcoveBoostBridge.postMessage({kind,nonce,...extra});
      state.claim=(n,h,key)=>{if(!valid(n,h)||state.ran.has(key))return false;state.ran.add(key);return true;};
      state.release=(n,key)=>{if(n===nonce)state.ran.delete(key);};
      state.apply=(n,h,serial,appearance,css,selectors)=>{
        if(!valid(n,h)||serial<state.serial) return false;
        const styles=[];
        for(const text of [appearance,css]) if(text){const sheet=new CSSStyleSheet();sheet.replaceSync(text);styles.push(sheet);}
        if(selectors.length){
          for(const selector of selectors) document.querySelector(selector);
          const sheet=new CSSStyleSheet();
          sheet.replaceSync('@layer alcoveZaps {'+selectors.map(s=>s+'{display:none!important}').join('\n')+'}');
          styles.push(sheet);
        }
        document.adoptedStyleSheets=[...document.adoptedStyleSheets.filter(s=>!state.sheets.includes(s)),...styles];
        state.sheets=styles;state.serial=serial;return true;
      };
      const selectorFor=element=>{
        if(!(element instanceof Element)||element===document.documentElement||element===document.body) return null;
        if(element.id){const id='#'+CSS.escape(element.id);if(document.querySelectorAll(id).length===1)return id;}
        let node=element,parts=[];
        for(let depth=0;node&&node!==document.documentElement&&depth<32;depth++,node=node.parentElement){
          if(!node.parentElement)break;
          const siblings=[...node.parentElement.children].filter(e=>e.localName===node.localName&&e.namespaceURI===node.namespaceURI);
          parts.unshift(CSS.escape(node.localName)+':nth-of-type('+(siblings.indexOf(node)+1)+')');
          const selector=parts.join(' > ');
          if(new TextEncoder().encode(selector).length>1024)return null;
          const matches=document.querySelectorAll(selector);
          if(matches.length===1&&matches[0]===element)return selector;
        }
        return null;
      };
      state.stopPicker=()=>{
        const p=state.picker;if(!p)return;
        state.picker=null;state.pendingPick=null;p.overlay.remove();
        document.adoptedStyleSheets=document.adoptedStyleSheets.filter(s=>s!==p.overlaySheet&&s!==p.hoverSheet);
        document.removeEventListener('keydown',p.key,true);
      };
      state.pick=element=>{
        const p=state.picker;if(!p)return false;
        const selector=selectorFor(element);
        if(!selector){post('pickerError',{picker:p.id,selection:p.selection});return false;}
        p.hoverSheet.replaceSync('');
        state.pendingPick={element,selector,selection:p.selection};
        post('picked',{picker:p.id,selection:p.selection,selector});return true;
      };
      state.validatePick=(n,h,selection,selector)=>{
        if(!valid(n,h)||!state.picker||state.picker.selection!==selection)return false;
        const p=state.pendingPick;if(!p||p.selection!==selection||p.selector!==selector||!p.element.isConnected)return false;
        const nodes=document.querySelectorAll(selector);return nodes.length===1&&nodes[0]===p.element;
      };
      state.startPicker=(n,h,id,selection)=>{
        if(!valid(n,h)||!document.documentElement)return false;
        if(state.picker?.id===id){state.picker.selection=selection;state.pendingPick=null;return true;}
        state.stopPicker();
        const overlay=document.createElement('div'),overlayID='alcove-zap-'+nonce;
        overlay.id=overlayID;overlay.setAttribute('data-alcove-zap-overlay','');overlay.setAttribute('aria-hidden','true');
        const overlaySheet=new CSSStyleSheet(),hoverSheet=new CSSStyleSheet();
        overlaySheet.replaceSync('#'+overlayID+'{all:initial!important;display:block!important;position:fixed!important;inset:0!important;z-index:2147483647!important;cursor:crosshair!important;pointer-events:auto!important;background:transparent!important;}');
        const target=event=>document.elementsFromPoint(event.clientX,event.clientY).find(e=>e!==overlay);
        overlay.addEventListener('mousemove',event=>{
          const selector=selectorFor(target(event));
          hoverSheet.replaceSync(selector?selector+'{outline:3px solid #7855ef!important;outline-offset:-3px!important;}':'');
        });
        overlay.addEventListener('click',event=>{
          event.preventDefault();event.stopImmediatePropagation();
          if(event.isTrusted)state.pick(target(event));
        },true);
        const key=event=>{if(event.isTrusted&&event.key==='Escape'&&!event.isComposing&&event.keyCode!==229){event.preventDefault();event.stopImmediatePropagation();post('cancelPicker',{picker:id});}};
        state.picker={id,selection,overlay,overlaySheet,hoverSheet,key};
        document.documentElement.append(overlay);
        document.adoptedStyleSheets=[...document.adoptedStyleSheets,overlaySheet,hoverSheet];
        document.addEventListener('keydown',key,true);return true;
      };
      post('start');
      const ready=()=>{state.ready=true;post('ready');};
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else queueMicrotask(ready);
    })();
    """#
}
