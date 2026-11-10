import Foundation
import JavaScriptCore
import WebKit

/// Structural preflight shared by saving and the isolated runtime. WebKit still
/// determines supported selectors, properties and values; replaceSync alone
/// silently repairs unfinished input and is not a validation boundary.
enum BoostCSS {
    static let preflight = #"""
    css => {
      let i=0,depth=0;const roots=[];
      const error=message=>{throw new Error('CSS: '+message);};
      const escape=/\\(?:([0-9a-f]{1,6})[\t\n\r\f ]?|([^\r\n\f]))/gi;
      const decode=text=>text.replace(escape,(_,hex,character)=>{
        if(!hex)return character;
        const point=parseInt(hex,16);return String.fromCodePoint(!point||point>0x10ffff||(point>=0xd800&&point<=0xdfff)?0xfffd:point);
      });
      const rule=prefix=>{
        const match=prefix[0]==='@'?decode(prefix).match(/^@[-\w\u0080-\uFFFF]+/):null;
        if(prefix[0]==='@'&&!match)error('Add an at-rule name after @.');
        return {prefix,kind:match?match[0].toLowerCase().replace('@-webkit-keyframes','@keyframes'):'style',properties:[],rules:[]};
      };
      const quoted=quote=>{
        const start=i++;
        while(i<css.length){
          const c=css[i++];
          if(c===quote)return css.slice(start,i);
          if(c==='\\'){if(i===css.length)error('Finish the escaped string.');if(css[i]==='\r'&&css[i+1]==='\n')i++;i++;}
          else if(c==='\n'||c==='\r'||c==='\f')error('Close the quoted string before a line break.');
        }
        error('Close the quoted string.');
      };
      const comment=()=>{
        const end=css.indexOf('*/',i+2);
        if(end<0)error('Close the comment with */.');
        i=end+2;
      };
      const group=close=>{
        if(++depth>128)error('Reduce deeply nested groups.');
        const start=i++;
        while(i<css.length){
          const c=css[i];
          if(c===close){i++;depth--;return css.slice(start,i);}
          if(c==='"'||c==="'"){quoted(c);continue;}
          if(c==='/'&&css[i+1]==='*'){comment();continue;}
          if(c==='\\'){i+=2;continue;}
          if(c==='('||c==='['||c==='{'){group(c==='('?')':c==='['?']':'}');continue;}
          if(c===')'||c===']'||c==='}')error('Match opening and closing brackets.');
          i++;
        }
        error('Close every bracket and rule.');
      };
      const declaration=(text,node)=>{
        text=text.trim();if(!text)return;
        if(text[0]==='@')return;
        const colon=text.indexOf(':'),property=text.slice(0,colon).trim();
        if(colon<1||!/^(?:--|-?(?:[a-zA-Z_\u0080-\uFFFF]|\\))(?:[^\s:;{}]|\\.)*$/.test(property.replace(escape,'X')))error('Write declarations as property: value.');
        if(!property.startsWith('--')&&!text.slice(colon+1).replace(/!\s*important\s*$/i,'').trim())error('Add a value after '+property+':.');
        const decoded=decode(property),name=decoded.startsWith('--')?decoded:decoded.toLowerCase();
        node.properties.push({name,value:text.slice(colon+1).replace(/!\s*important\s*$/i,'').trim()});
      };
      const statement=(text,mode,node)=>{
        text=text.trim();if(!text)return;
        if(/^@import\b/i.test(decode(text)))error('@import is not supported in a Boost. Paste the rules directly.');
        if(mode&&text[0]!=='@')declaration(text,node);
        else{
          if(text[0]!=='@')error('Put website rules inside selector { declarations }.');
          if(/^@charset\b/i.test(decode(text))){
            if(!/^@charset\s+(?:"[^"\r\n]+"|'[^'\r\n]+')$/i.test(decode(text)))error('Write @charset with a quoted encoding.');
          }else (node?node.rules:roots).push(rule(text));
        }
      };
      const list=(mode,closing=false,node=null)=>{
        if(++depth>128)error('Reduce deeply nested rules.');
        let text='';
        while(i<css.length){
          const c=css[i];
          if(c==='/'&&css[i+1]==='*'){comment();text+=' ';continue;}
          if(c==='"'||c==="'"){text+=quoted(c);continue;}
          if(c==='\\'){if(i+1>=css.length)error('Finish the escape.');text+=css.slice(i,i+2);i+=2;continue;}
          if(c==='('||c==='['){text+=group(c==='('?')':']');continue;}
          if(c===')'||c===']')error('Match opening and closing brackets.');
          if(c==='{'){
            if(mode&&/^\s*--[^:]+:/.test(text)){text+=group('}');continue;}
            const prefix=text.trim();text='';
            if(!prefix)error('Add a selector or at-rule before {.');
            const child=rule(prefix);(node?node.rules:roots).push(child);
            i++;
            const grouping=/^@(?:media|supports|layer|container|scope|keyframes|document)$/.test(child.kind);
            list(!grouping,true,child);continue;
          }
          if(c===';'){statement(text,mode,node);text='';i++;continue;}
          if(c==='}'){
            if(!closing)error('Remove the unmatched closing brace.');
            statement(text,mode,node);i++;depth--;return;
          }
          text+=c;i++;
        }
        if(closing)error('Close every rule with }.');
        statement(text,mode,node);depth--;
      };
      list(false);return roots;
    }
    """#

    /// Compare the intended structure with rules actually retained by WebKit.
    /// The sheet is never adopted, so validation cannot load CSS resources.
    static let enginePreflight = #"""
    css=>{
      const parse=\#(preflight),expected=parse(css),sheet=new CSSStyleSheet();
      sheet.replaceSync(css);
      const actual=parse([...sheet.cssRules].map(rule=>rule.cssText).join('\n'));
      const compare=(wanted,retained)=>{
        if(wanted.length!==retained.length)throw new Error('CSS: WebKit rejected a selector or unsupported rule. Your saved rules were kept.');
        for(let i=0;i<wanted.length;i++){
          const a=wanted[i],b=retained[i];
          if(a.kind!==b.kind)throw new Error('CSS: WebKit could not retain this rule.');
          const names=new Set(b.properties.map(p=>p.name));
          for(const property of a.properties)if(!names.has(property.name)){
            // CSSOM may combine shorthands/aliases. A supported style value is
            // still valid even when its spelling changes in serialization.
            if(a.kind==='style'&&a.properties.some(p=>p.name===property.name&&CSS.supports(p.name,p.value)))continue;
            throw new Error('CSS: WebKit rejected the '+property.name+' property or value. Your saved rules were kept.');
          }
          compare(a.rules,b.rules);
        }
      };
      compare(expected,actual);return true;
    }
    """#

    struct Validation {
        fileprivate let css: String
        func matches(_ value: String) -> Bool { css == value }
    }
    @MainActor private static var parser: WKWebView?

    @MainActor static func checked(_ css: String) async throws -> Validation {
        try validate(css)
        if css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Validation(css: css) }
        let web: WKWebView
        if let parser { web = parser }
        else {
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            web = WKWebView(frame: .zero, configuration: configuration); parser = web
            web.loadHTMLString("<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>CSS validation</title>", baseURL: nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while web.url == nil || web.isLoading {
            guard ContinuousClock.now < deadline else { parser = nil; throw failure("CSS validation did not become ready. Try saving again.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = BoostCSSReply(continuation)
            reply.timeout = Task { @MainActor [weak reply, weak web] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if parser === web { parser = nil }
                reply?.finish(.failure(failure("CSS validation did not respond. Try saving again.")))
            }
            web.callAsyncJavaScript("return (" + enginePreflight + ")(css);", arguments: ["css": css], in: nil, in: .page) { result in
                switch result {
                case .success: reply.finish(.success(()))
                case .failure(let error):
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    reply.finish(.failure(failure(detail ?? "CSS: WebKit could not validate these rules. Your saved rules were kept.")))
                }
            }
        }
        return Validation(css: css)
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Alcove.BoostCSS", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor static func validate(_ css: String) throws {
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let context = JSContext(), let function = context.evaluateScript("(" + preflight + ")") else {
            throw NSError(domain: "Alcove.BoostCSS", code: 1, userInfo: [NSLocalizedDescriptionKey: "CSS validation is unavailable. Your saved rules were kept."])
        }
        _ = function.call(withArguments: [css])
        if let error = context.exception {
            throw NSError(domain: "Alcove.BoostCSS", code: 2, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "CSS: Finish the rule before saving."])
        }
    }
}

@MainActor private final class BoostCSSReply {
    private var continuation: CheckedContinuation<Void, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil; continuation.resume(with: result)
    }
}
