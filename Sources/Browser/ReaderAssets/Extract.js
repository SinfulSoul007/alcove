// Alcove's local boundary around Mozilla Readability. Runs in a private content
// world. Only the clone is mutated; no raw extracted HTML reaches the renderer.
if (!['text/html', 'application/xhtml+xml'].includes(document.contentType)) return { error: 'unsupported' };
if (!document.body || !document.documentElement) return { error: 'unavailable' };
const elements = document.getElementsByTagName('*');
if (elements.length > 50000) return { error: 'tooLarge' };
// Bound everything a clone copies, including large inline scripts/styles, data
// attributes and comments outside the article. Avoid joining the whole DOM text.
let inputSize = location.href.length, attributeCount = 0, textCount = 0;
if (document.doctype) inputSize += document.doctype.name.length + document.doctype.publicId.length + document.doctype.systemId.length;
if (inputSize > 2000000) return { error: 'tooLarge' };
for (const element of elements) {
    for (const attribute of element.attributes) {
        inputSize += attribute.name.length + attribute.value.length;
        if (++attributeCount > 200000 || inputSize > 2000000) return { error: 'tooLarge' };
    }
}
const walker = document.createTreeWalker(document, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_COMMENT | NodeFilter.SHOW_PROCESSING_INSTRUCTION);
while (walker.nextNode()) {
    inputSize += walker.currentNode.nodeValue.length;
    if (++textCount > 100000 || inputSize > 2000000) return { error: 'tooLarge' };
}
// Iterative depth check also bounds custom/script-built DOMs before native clone
// or Readability's transformations can encounter pathological nesting.
let cursor = document, depth = 0;
while (cursor) {
    if (cursor.firstChild) {
        cursor = cursor.firstChild;
        if (++depth > 256) return { error: 'tooLarge' };
    } else {
        while (cursor && !cursor.nextSibling) { cursor = cursor.parentNode; --depth; }
        if (cursor) cursor = cursor.nextSibling;
    }
}
const copy = document.cloneNode(true);
const article = new Readability(copy, { maxElemsToParse: 50000, charThreshold: 400, disableJSONLD: true, serializer: node => node }).parse();
if (!article || !article.content || !article.textContent || article.textContent.trim().length < 400) return { error: 'unavailable' };
const escapeText = text => String(text).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const allowed = new Set(['p','h1','h2','h3','h4','h5','h6','ul','ol','li','blockquote','pre','code','strong','b','em','i','u','s','del','small','sub','sup','br','hr','figure','figcaption','table','thead','tbody','tfoot','tr','th','td','caption','dl','dt','dd','div','span','a']);
const removed = new Set(['script','style','iframe','frame','object','embed','video','audio','svg','math','canvas','source','input','form','button','select','textarea','link','meta','base','noscript','template']);
let textBudget = 0, nodes = 0;
function serialize(node, depth = 0) {
    if (++nodes > 50000 || depth > 128) throw new Error('Reader output too complex');
    if (node.nodeType === 3) {
        textBudget += node.nodeValue.length;
        if (textBudget > 500000) throw new Error('Reader output too large');
        return escapeText(node.nodeValue);
    }
    if (node.nodeType !== 1) return '';
    const tag = node.localName.toLowerCase();
    if (removed.has(tag)) return '';
    if (tag === 'img') return node.alt ? '<span>[Image: ' + escapeText(node.alt.slice(0, 500)) + ']</span>' : '';
    const children = Array.from(node.childNodes, child => serialize(child, depth + 1)).join('');
    if (!allowed.has(tag)) return children;
    if (tag === 'a') {
        try {
            const url = new URL(node.getAttribute('href') || '', location.href);
            if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return children;
            return '<a href="' + escapeText(url.href) + '">' + children + '</a>';
        } catch (_) { return children; }
    }
    return '<' + tag + '>' + children + (tag === 'br' || tag === 'hr' ? '' : '</' + tag + '>');
}
try {
    const html = serialize(article.content);
    if (html.length > 1000000) return { error: 'tooLarge' };
    return { html, title: (article.title || document.title || 'Article').slice(0, 1000), byline: (article.byline || '').slice(0, 500), site: (article.siteName || '').slice(0, 300), direction: article.dir === 'rtl' ? 'rtl' : 'ltr', length: article.textContent.length };
} catch (_) { return { error: 'tooLarge' }; }
