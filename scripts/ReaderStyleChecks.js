// Runs only inside the generated owned fixture, using real browser text layout.
(async () => {
    const results = [];
    function check(value, label) { results.push({ pass: !!value, label }); }
    function passage() {
        const box = document.querySelector('main').getBoundingClientRect();
        const range = document.caretRangeFromPoint(box.left + 16, 32);
        if (!range || range.startContainer.nodeType !== 3) throw new Error('No visible text passage');
        const node = range.startContainer, offset = Math.min(range.startOffset, node.length - 1);
        range.setStart(node, offset); range.setEnd(node, offset + 1);
        return { range, node, offset, text: node.data.slice(offset, offset + 48), top: range.getBoundingClientRect().top };
    }
    async function stable(anchor) {
        let last = null, same = 0;
        for (let i = 0; i < 30; ++i) {
            await new Promise(resolve => setTimeout(resolve, 16));
            const top = anchor.range.getBoundingClientRect().top;
            same = last !== null && Math.abs(top - last) < 0.1 ? same + 1 : 0;
            if (same >= 2) return;
            last = top;
        }
        throw new Error('Passage geometry did not settle');
    }
    function matches(anchor) {
        return anchor.node.isConnected && anchor.range.startContainer === anchor.node
            && anchor.range.startOffset === anchor.offset && anchor.node.data.slice(anchor.offset, anchor.offset + 48) === anchor.text
            && Math.abs(anchor.range.getBoundingClientRect().top - anchor.top) <= 2;
    }
    function putInside(id, offset) {
        const node = document.getElementById(id).firstChild;
        const target = document.createRange(); target.setStart(node, offset); target.setEnd(node, offset + 1);
        window.scrollTo(0, window.scrollY + target.getBoundingClientRect().top - 32);
    }
    try {
        const paper = '#202225', ink = '#e1dfda', muted = '#aaa8a3', link = '#9abef5';
        putInside('passage-18', 900);
        const original = passage();
        check(original.offset > 100 && original.node.parentElement.id === 'passage-18', 'Fixture starts inside a long paragraph at a real visible text position');
        applyStyle(paper, ink, muted, link, 30, 720, 'Georgia, Charter, serif');
        await stable(original);
        check(matches(original), 'Text-size reflow preserves the same visible passage and vertical position');
        applyStyle(paper, ink, muted, link, 30, 720, '-apple-system, BlinkMacSystemFont, sans-serif');
        await stable(original);
        check(matches(original), 'Typeface reflow preserves the same visible passage and vertical position');
        applyStyle(paper, ink, muted, link, 30, 480, '-apple-system, BlinkMacSystemFont, sans-serif');
        await stable(original);
        check(matches(original), 'Width reflow preserves the same visible passage and vertical position');
        check(document.documentElement.style.getPropertyValue('--size') === '30px' && document.documentElement.style.getPropertyValue('--width') === '480px', 'Requested typography and width are applied');
        putInside('passage-39', 800);
        const moved = passage();
        applyStyle(paper, ink, muted, link, 18, 800, 'Georgia, Charter, serif');
        await stable(moved);
        check(matches(moved) && moved.node.parentElement.id === 'passage-39', 'A user scroll establishes a new passage instead of restoring an old anchor');
        window.scrollTo(0, 0);
        applyStyle(paper, ink, muted, link, 24, 560, 'Georgia, Charter, serif');
        check(window.scrollY === 0, 'Appearance changes keep the start of the article at the top');
    } catch (error) { results.push({ pass: false, label: 'Fixture error: ' + error.message }); }
    const output = document.createElement('pre'); output.id = 'reader-style-result';
    output.textContent = JSON.stringify({ checks: results, failures: results.filter(item => !item.pass).length });
    document.body.appendChild(output);
})();
