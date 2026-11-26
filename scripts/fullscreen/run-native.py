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
ARTICLE = HTML + ('<article><h1>The owned fullscreen report</h1><p>' +
                  ('A patient reader follows the river through the mountains. '
                   'This report explains the landscape, its history, and the people who live here. ' * 60) +
                  '</p></article>').encode()
NO_MEDIA = b'''<!doctype html><meta charset="utf-8"><title>Owned fullscreen without media</title>
<style>body{margin:0;background:#dee7ed}#element{height:240px;padding:24px;box-sizing:border-box;background:#345;color:white}
button{padding:16px;font:18px system-ui}:fullscreen{background:#345}#spacer{height:2400px}</style>
<div id="element"><button id="enter">Enter fullscreen</button></div>
<input id="draft" value="original"><div id="spacer"></div>
<script>window.ownedFullscreenResult='not-requested';
document.getElementById('enter').addEventListener('click',event=>{
  window.ownedClickTrace={trusted:event.isTrusted,active:navigator.userActivation.isActive};
  window.ownedFullscreenResult='requesting';
  document.getElementById('element').requestFullscreen()
    .then(()=>window.ownedFullscreenResult='entered')
    .catch(error=>window.ownedFullscreenResult=error.name+': '+error.message);
});</script>'''


def command(args, *, timeout=300, env=None):
    print('FULLSCREEN_STAGE', Path(args[0]).name, args[-1], flush=True)
    subprocess.run(args, cwd=ROOT, check=True, timeout=timeout, env=env)


def pinned_media():
    video = OUT / 'test-25fps.mp4'
    if not video.exists() or hashlib.sha256(video.read_bytes()).hexdigest() != VIDEO_SHA256:
        with urllib.request.urlopen(VIDEO_URL, timeout=45) as response:
            data = response.read(2_000_001)
        if len(data) > 2_000_000 or hashlib.sha256(data).hexdigest() != VIDEO_SHA256:
            raise RuntimeError('Pinned upstream test video failed its integrity check')
        video.write_bytes(data)
    return video.read_bytes()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--typecheck-only', action='store_true')
    parser.add_argument('--exit-control-only', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    sdk = os.environ.get('BROWSER_SDK') or subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    pinned_sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
    if not os.environ.get('BROWSER_SDK') and pinned_sdk.is_dir():
        sdk = str(pinned_sdk)
    arch = os.environ.get('BROWSER_ARCH') or os.uname().machine
    flags = ['-sdk', sdk, '-module-cache-path', str(OUT / 'cache'), '-target', f'{arch}-apple-macosx14.0']
    if args.exit_control_only:
        executable = OUT / 'stock-fullscreen-exit-control'
        command(['xcrun', 'swiftc', *flags, '-parse-as-library', '-warnings-as-errors',
                 'scripts/fullscreen/ExitControl.swift', '-o', str(executable)])
        if not args.compile_only:
            media = pinned_media()
            class ControlHandler(BaseHTTPRequestHandler):
                def do_GET(self):
                    body, content_type = (media, 'video/mp4') if self.path == '/video.mp4' else (HTML, 'text/html; charset=utf-8')
                    self.send_response(200)
                    self.send_header('Content-Type', content_type)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *_):
                    pass

            server = ThreadingHTTPServer(('127.0.0.1', 0), ControlHandler)
            server.daemon_threads = True
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                env = dict(os.environ, ALCOVE_FULLSCREEN_FIXTURE_URL=f'http://127.0.0.1:{server.server_port}/')
                command([str(executable)], timeout=80, env=env)
            finally:
                server.shutdown(); server.server_close(); worker.join(timeout=5)
        return
    core = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/BrowserCore').glob('*.swift'))
    sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources/Browser').glob('*.swift') if p.name != 'main.swift')
    command(['xcrun', 'swiftc', *flags, '-emit-module', '-emit-library', '-enable-testing', '-module-name', 'BrowserCore', *core,
             '-o', str(OUT / 'libBrowserCore.dylib'), '-emit-module-path', str(OUT / 'BrowserCore.swiftmodule')])
    native = ['xcrun', 'swiftc', *flags, '-parse-as-library', '-warnings-as-errors', '-I', str(OUT), *sources,
              'scripts/WebsiteFullscreenChecks.swift', 'scripts/WebsiteFullscreenContextChecks.swift',
              'scripts/WebsiteFullscreenCommandChecks.swift',
              'scripts/WebsiteFullscreenProfileDeletionChecks.swift',
              'scripts/OwnedWebsiteStores.swift', 'scripts/OwnedExtensionControllers.swift']
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
    media = pinned_media()
    media_requests = 0

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal media_requests
            if self.path == '/video.mp4':
                media_requests += 1
                body, content_type = media, 'video/mp4'
            elif self.path == '/page':
                body, content_type = HTML, 'text/html; charset=utf-8'
            elif self.path == '/article':
                body, content_type = ARTICLE, 'text/html; charset=utf-8'
            elif self.path == '/page-no-media':
                body, content_type = NO_MEDIA, 'text/html; charset=utf-8'
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
        # Separate processes retain the same per-operation and process bounds.
        # The expanded matrix must finish every case; a partial aggregate run
        # cannot qualify a case it never reached. Run every group after failure.
        selected = bool(env.get('ALCOVE_FULLSCREEN_COMMAND_CASES', ''))
        groups = ['diagnostic'] if selected else ['primary', 'private-primary', 'quick']
        failed = []
        for group in groups:
            group_env = dict(env)
            if selected:
                group_env.pop('ALCOVE_FULLSCREEN_COMMAND_GROUP', None)
            else:
                group_env['ALCOVE_FULLSCREEN_COMMAND_GROUP'] = group
            print('FULLSCREEN_PROCESS_GROUP_STARTED', group, flush=True)
            try:
                command([str(executable)], timeout=325, env=group_env)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                failed.append(group)
                print('FULLSCREEN_PROCESS_GROUP_FAILED', group, type(error).__name__, flush=True)
            else:
                print('FULLSCREEN_PROCESS_GROUP_PASSED', group, flush=True)
        if failed:
            raise RuntimeError('Native fullscreen groups failed: ' + ', '.join(failed))
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        print('FULLSCREEN_SERVER_VIDEO_REQUESTS', media_requests, flush=True)


if __name__ == '__main__':
    main()
