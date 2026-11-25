// Optional fast DOM gate. jsdom is a test-only dependency; the app ships no Node
// runtime. Run with NODE_PATH pointing to a pinned jsdom 26.1.0 installation.
// HTML scripts, event handlers and external resources are never enabled.
const { JSDOM } = require('jsdom');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const root = path.join(__dirname, '../Sources/Browser/ReaderAssets');
const script = readFileSync(path.join(root, 'Readability.js'), 'utf8') + '\n' + readFileSync(path.join(root, 'Extract.js'), 'utf8');
const prose = 'A patient reader follows the river through the mountains. This detailed report explains the landscape, its history, and the people who live here. '.repeat(20);
const article = `<article><h1>The River Report</h1><p>${prose}</p><h2>Along the valley</h2><p>${prose}</p><p><strong>Evidence</strong> and <a href="/follow">further reading</a>.</p></article>`;
let checks = 0, failures = 0;
function check(value, label) { ++checks; if (!value) ++failures; console.log(`${value ? 'PASS' : 'FAIL'}: ${label}`); }
function extract(body, head = '<title>The River Report</title>', contentType = 'text/html', prefix = '') {
    const namespace = contentType === 'application/xhtml+xml' ? ' xmlns="http://www.w3.org/1999/xhtml"' : '';
    const dom = new JSDOM(`${prefix}<html${namespace}><head>${head}</head><body>${body}</body></html>`, { url: 'https://reader.alcove.example/story', contentType, runScripts: 'outside-only' });
    try {
        const draft = dom.window.document.querySelector('input');
        if (draft) draft.value = 'typed draft';
        dom.window.sourceSentinel = 42;
        const before = dom.window.document.documentElement.outerHTML;
        const output = new dom.window.Function(script)();
        return { output, unchanged: dom.window.document.documentElement.outerHTML === before && (!draft || draft.value === 'typed draft') && dom.window.sourceSentinel === 42 };
    } finally { dom.window.close(); }
}
const basic = extract(`<nav>CHROME_NAVIGATION <a href="/noise">Account</a></nav>${article}<form><input value="original"></form>`);
check(basic.output.html?.includes('<h2>Along the valley</h2>') && basic.output.html.includes('<strong>Evidence</strong>'), 'Real extractor preserves headings and emphasis');
check(!basic.output.html?.includes('CHROME_NAVIGATION') && !basic.output.html?.includes('<form'), 'Real extractor excludes navigation chrome and forms');
check(basic.output.html?.includes('https://reader.alcove.example/follow'), 'Relative article links resolve to their source');
check(basic.unchanged, 'Clone extraction preserves original DOM, form values and globals');
const hostile = extract(article.replace('</article>', `<p>Safe text <a href="javascript:alert(1)">bad link</a><a href="&#106;avascript:alert(2)">encoded link</a><a href="data:text/html,evil">data link</a><a href="https://user:password@reader.alcove.example/private">credential link</a><a href="https://reader.alcove.example/ok?x=&quot;">good link</a><span onclick="alert(1)" style="background:url(https://leak.invalid)">styled text</span><img src="https://leak.invalid/pixel" onerror="alert(1)" alt="River &lt;script&gt;">${prose}<iframe src="https://leak.invalid"></iframe><svg onload="alert(1)"><a href="javascript:alert(1)">SVG</a></svg><math><mtext><img src=x onerror="alert(1)"></mtext></math></p></article>`));
const fragment = JSDOM.fragment(hostile.output.html || '');
const nodes = [...fragment.querySelectorAll('*')];
const allowed = new Set(['P','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE','CODE','STRONG','B','EM','I','U','S','DEL','SMALL','SUB','SUP','BR','HR','FIGURE','FIGCAPTION','TABLE','THEAD','TBODY','TFOOT','TR','TH','TD','CAPTION','DL','DT','DD','DIV','SPAN','A']);
check(nodes.length > 0 && nodes.every(node => allowed.has(node.tagName)), 'Only the structural HTML allowlist survives hostile markup');
check(nodes.every(node => [...node.attributes].every(attr => node.tagName === 'A' && attr.name === 'href' && /^https?:/.test(attr.value) && !new URL(attr.value).username)), 'All event handlers, style, resource URLs and privileged schemes are stripped');
check(fragment.textContent.includes('bad link') && fragment.textContent.includes('encoded link') && fragment.textContent.includes('data link') && fragment.textContent.includes('credential link') && fragment.querySelector('a[href^="https://reader.alcove.example/ok"]'), 'Unsafe links keep readable text while safe links remain available');
check(hostile.unchanged, 'Hostile extraction also leaves the original document and drafts untouched');
check(extract('<p>Short page</p>').output.error === 'unavailable', 'Short pages give honest unavailability');
check(extract('x'.repeat(2000001)).output.error === 'tooLarge', 'Oversized body text is rejected before cloning');
check(extract(article, `<script>${'x'.repeat(2000001)}</script>`).output.error === 'tooLarge', 'Oversized head content is rejected before cloning');
check(extract(article.replace('<article>', `<article data-payload="${'x'.repeat(2000001)}">`)).output.error === 'tooLarge', 'Oversized attributes are rejected before cloning');
check(extract(article, `<!--${'x'.repeat(2000001)}-->`).output.error === 'tooLarge', 'Oversized comments are rejected before cloning');
check(extract(article, '', 'text/html', `<!--${'x'.repeat(2000001)}-->`).output.error === 'tooLarge', 'Document-level comments are budgeted before cloning');
check(extract('<div>'.repeat(300) + article + '</div>'.repeat(300)).output.error === 'tooLarge', 'Excessive source nesting is rejected before cloning');
const ordinaryTemplates = extract(article + '<template><section>Small template<template><b>Nested template</b></template></section></template>');
check(ordinaryTemplates.output.html?.includes('Along the valley') && ordinaryTemplates.unchanged, 'Ordinary nested templates do not prevent reading or mutate the source');
check(extract(article + `<template>${'x'.repeat(2000001)}</template>`).output.error === 'tooLarge', 'Template fragment text is budgeted before cloning');
check(extract(article + `<template><template><div data-payload="${'x'.repeat(2000001)}"></div></template></template>`).output.error === 'tooLarge', 'Nested template attributes are budgeted before cloning');
check(extract(article + '<template>' + '<div></div>'.repeat(25000) + '</template><template>' + '<div></div>'.repeat(25000) + '</template>').output.error === 'tooLarge', 'Element budgets accumulate across separate template fragments');
check(extract(article + '<template>'.repeat(140) + '<p>nested</p>' + '</template>'.repeat(140)).output.error === 'tooLarge', 'Nested template fragment depth is bounded before cloning');
const anchorOutput = extract(article.replace('</article>', '<p><a>Anchor label</a><a href="">Explicit empty link</a><a href="#section">Explicit fragment link</a></p></article>'));
const anchors = JSDOM.fragment(anchorOutput.output.html || '');
check(anchors.textContent.includes('Anchor label') && ![...anchors.querySelectorAll('a')].some(a => a.textContent === 'Anchor label'), 'Href-less anchors retain their text without becoming navigation');
check([...anchors.querySelectorAll('a')].some(a => a.textContent === 'Explicit empty link' && a.href === 'https://reader.alcove.example/story') && [...anchors.querySelectorAll('a')].some(a => a.textContent === 'Explicit fragment link' && a.href === 'https://reader.alcove.example/story#section'), 'Explicit empty and fragment href semantics remain intact');
const xhtml = extract(`<article><h1>River report</h1><p><![CDATA[Story <river> & valley. ${prose}]]></p><p><![CDATA[${prose}]]></p></article>`, '<title>River report</title>', 'application/xhtml+xml');
check(xhtml.output.html?.includes('A patient reader follows the river') && xhtml.output.html.includes('&lt;river&gt; &amp; valley.') && xhtml.unchanged, 'Ordinary XHTML CDATA article text is preserved and escaped');
check(extract(`<article><p><![CDATA[${'x'.repeat(2000001)}]]></p></article>`, '<title>Large XHTML</title>', 'application/xhtml+xml').output.error === 'tooLarge', 'Oversized XHTML CDATA is rejected before cloning');
check(extract(article, '', 'application/xml').output.error === 'unsupported', 'Non-HTML documents are unsupported');
console.log('READER_DOM_CHECKS', checks, 'FAILURES', failures);
process.exitCode = failures ? 1 : 0;
