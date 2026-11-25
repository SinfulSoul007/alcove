#!/usr/bin/env python3
"""Build app-source regression and run only owned native windows/loopback pages."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import threading
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '.build' / 'fullscreen'
VIDEO_URL = 'https://raw.githubusercontent.com/WebKit/WebKit/26695efdefc6076049ec50713a2c4e54b90b4d47/LayoutTests/media/content/test-25fps.mp4'
VIDEO_SHA256 = 'c2f0f7007861ab196d31d6d9d62a01e4bd4a4158b2d6cd696105c09e9d8d61e6'
HTML = b'''<!doctype html><meta charset="utf-8"><title>Owned fullscreen fixture</title>
<style>body{margin:0;background:#dee7ed}#element{height:240px;background:#345;color:white}
:fullscreen{background:#345}#spacer{height:2400px}video{width:400px;height:240px}</style>
<div id="element">Owned generic fullscreen element</div>
<video id="video" src="/video.mp4" preload="auto" muted loop controls></video>
<input id="draft" value="original"><div id="spacer"></div>'''


def command(args, *, timeout=300, env=None):
    print('FULLSCREEN_STAGE', Path(args[0]).name, args[-1], flush=True)
    subprocess.run(args, cwd=ROOT, check=True, timeout=timeout, env=env)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--typecheck-only', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    sdk = os.environ.get('BROWSER_SDK') or subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    pinned_sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
    if not os.environ.get('BROWSER_SDK') and pinned_sdk.is_dir():
        sdk = str(pinned_sdk)
    arch = os.environ.get('BROWSER_ARCH') or os.uname().machine
    flags = ['-sdk', sdk, '-module-cache-path', str(OUT / 'cache'), '-target', f'{arch}-apple-macosx14.0']
    core = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/BrowserCore').glob('*.swift'))
    sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/Browser').glob('*.swift') if p.name != 'main.swift')
    command(['xcrun', 'swiftc', *flags, '-emit-module', '-emit-library', '-enable-testing', '-module-name', 'BrowserCore', *core,
             '-o', str(OUT / 'libBrowserCore.dylib'), '-emit-module-path', str(OUT / 'BrowserCore.swiftmodule')])
    native = ['xcrun', 'swiftc', *flags, '-parse-as-library', '-warnings-as-errors', '-I', str(OUT), *sources, 'scripts/WebsiteFullscreenChecks.swift']
    if args.typecheck_only:
        command([*native, '-typecheck'])
        return
    executable = OUT / 'website-fullscreen-checks'
    command([*native, '-L', str(OUT), '-lBrowserCore', '-Xlinker', '-rpath', '-Xlinker', '@executable_path', '-o', str(executable)])
    for folder in ['ReaderAssets', 'WebsiteProtection']:
        source = ROOT / ('Sources/Browser' if folder == 'ReaderAssets' else 'Resources') / folder
        shutil.copytree(source, OUT / folder, dirs_exist_ok=True)
    if args.compile_only:
        return
    video = OUT / 'test-25fps.mp4'
    if not video.exists() or hashlib.sha256(video.read_bytes()).hexdigest() != VIDEO_SHA256:
        with urllib.request.urlopen(VIDEO_URL, timeout=45) as response:
            data = response.read(2_000_001)
        if len(data) > 2_000_000 or hashlib.sha256(data).hexdigest() != VIDEO_SHA256:
            raise RuntimeError('Pinned upstream test video failed its integrity check')
        video.write_bytes(data)
    media = video.read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/video.mp4':
                body, content_type = media, 'video/mp4'
            elif self.path == '/page':
                body, content_type = HTML, 'text/html; charset=utf-8'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        env = dict(os.environ, ALCOVE_FULLSCREEN_FIXTURE_URL=f'http://127.0.0.1:{server.server_port}/')
        command([str(executable)], timeout=135, env=env)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


if __name__ == '__main__':
    main()
