#!/usr/bin/env python3
"""Real-layout Reader checks with a standalone headless-shell CLI, no debug port."""
import argparse, json, subprocess, tempfile
from html.parser import HTMLParser
from pathlib import Path

class Result(HTMLParser):
    def __init__(self): super().__init__(); self.capture = False; self.value = ''
    def handle_starttag(self, tag, attrs):
        if tag == 'pre' and dict(attrs).get('id') == 'reader-style-result': self.capture = True
    def handle_endtag(self, tag):
        if tag == 'pre': self.capture = False
    def handle_data(self, value):
        if self.capture: self.value += value

p = argparse.ArgumentParser()
p.add_argument('--headless-shell', required=True, type=Path)
p.add_argument('--fixture-generator', required=True, type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='alcove-reader-style-') as tmp:
    folder = Path(tmp); html = folder/'article.html'
    subprocess.run([str(a.fixture_generator.resolve()), str(root/'Sources/Browser/ReaderAssets'), str(root/'scripts/ReaderStyleChecks.js'), str(html)], check=True)
    command = [str(a.headless_shell.resolve()), '--headless', '--disable-gpu', '--disable-background-networking', '--no-first-run', '--no-default-browser-check', '--dump-dom', '--virtual-time-budget=5000', '--window-size=1000,700', '--user-data-dir='+str(folder/'profile'), html.as_uri()]
    run = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=45)
    parser = Result(); parser.feed(run.stdout)
    if run.returncode or not parser.value:
        print('READER_STYLE_FIXTURE_FAILED', run.returncode, run.stderr[-3000:])
        raise SystemExit(1)
    result = json.loads(parser.value)
    for item in result['checks']: print(('PASS' if item['pass'] else 'FAIL')+': '+item['label'])
    print('READER_STYLE_CHECKS', len(result['checks']), 'FAILURES', result['failures'])
    raise SystemExit(1 if result['failures'] else 0)
