// Trusted app code in Reader's isolated client world. Keep a real passage at the
// same viewport position across consecutive appearance edits, until the user
// scrolls or the viewport changes. Nothing is written to the original webpage.
const atTop = window.scrollY <= 1;
const connected = anchor => anchor && anchor.document === document
    && (anchor.range ? anchor.range.startContainer.isConnected : anchor.element.isConnected);
const rectangle = anchor => anchor.range ? anchor.range.getBoundingClientRect() : anchor.element.getBoundingClientRect();
let anchor = globalThis.alcoveReaderStyleAnchor;
if (atTop || !connected(anchor) || Math.abs(anchor.lastScrollY - window.scrollY) > 1
    || anchor.viewportWidth !== innerWidth || anchor.viewportHeight !== innerHeight) {
    anchor = null;
    if (!atTop) {
        const content = document.querySelector('main') || document.body;
        const bounds = content.getBoundingClientRect();
        const rtl = document.documentElement.dir === 'rtl';
        const x = Math.max(1, Math.min(innerWidth - 2, rtl ? bounds.right - 16 : bounds.left + 16));
        const y = Math.min(32, Math.max(1, innerHeight - 2));
        let range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (!range && document.caretPositionFromPoint) {
            const position = document.caretPositionFromPoint(x, y);
            if (position) { range = document.createRange(); range.setStart(position.offsetNode, position.offset); }
        }
        if (range && range.startContainer.nodeType === 3 && range.startContainer.length
            && range.startContainer.data.trim() && document.body.contains(range.startContainer)) {
            const node = range.startContainer, offset = Math.min(range.startOffset, node.length - 1);
            range.setStart(node, offset); range.setEnd(node, offset + 1);
            anchor = { document, range, top: range.getBoundingClientRect().top };
        } else {
            const target = document.elementFromPoint(x, y);
            const element = target && target.closest('p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,table,figure,figcaption,dt,dd');
            if (element) anchor = { document, element, top: element.getBoundingClientRect().top };
        }
    }
}
const root = document.documentElement.style;
root.setProperty('--paper', paper); root.setProperty('--ink', ink); root.setProperty('--muted', muted); root.setProperty('--link', link);
root.setProperty('--size', size + 'px'); root.setProperty('--width', width + 'px'); root.setProperty('--font', font);
if (atTop) window.scrollTo(window.scrollX, 0);
else if (connected(anchor)) {
    // Reading the rect forces the new text layout. The browser clamps at physical
    // document edges; in the middle the same character returns to the same y.
    window.scrollTo(window.scrollX, window.scrollY + rectangle(anchor).top - anchor.top);
    anchor.lastScrollY = window.scrollY;
    anchor.viewportWidth = innerWidth; anchor.viewportHeight = innerHeight;
}
globalThis.alcoveReaderStyleAnchor = anchor;
return true;
