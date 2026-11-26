#!/usr/bin/env python3
"""Build app-source regression and run only owned native windows/loopback pages."""
import argparse
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import threading
import tempfile
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
              'scripts/WebsiteFullscreenQuitChecks.swift',
              'scripts/WebsiteNativeLayoutChecks.swift',
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
        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                # An owned WebKit page can cancel a request or quit while the
                # loopback server is reading its next request. Page readiness
                # and all native assertions remain independent requirements.
                pass

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
        quit_cases = [prefix + kind for prefix in ['', 'private-', 'quick-', 'private-quick-'] for kind in ['quit', 'peek-quit']]
        layout_cases = {'layout-production', 'layout-normal-production', 'layout-no-motion-production', 'layout-collapsed-production', 'layout-single-tab-production', 'layout-minimum-control', 'layout-fixed-control', 'layout-preconfigured-control', 'layout-content-minimum-control', 'layout-web-content-control', 'layout-chrome-reader-control', 'layout-sidebar-row-control', 'layout-sidebar-scroll-control', 'layout-sidebar-saved-control', 'layout-chrome-feedback-control', 'layout-native-menus-control', 'layout-address-controls-control', 'layout-tracking-control', 'layout-store-sheet-control', 'layout-full-sidebar-control', 'layout-isolated-defaults-control', 'layout-progress-control', 'layout-content-frame-control', 'layout-resize-grip-control', 'layout-ignored-safe-area-control'}
        selection = [name for name in env.get('ALCOVE_FULLSCREEN_COMMAND_CASES', '').split(',') if name]
        selected_quits = [name for name in selection if name in quit_cases] if selection else quit_cases
        selected_layout = [name for name in selection if name in layout_cases]
        ordinary = [name for name in selection if name not in quit_cases and name not in layout_cases]
        groups = (['diagnostic'] if ordinary else []) if selection else ['primary', 'private-primary', 'quick']
        failed = []
        for group in groups:
            group_env = dict(env, ALCOVE_FULLSCREEN_SKIP_QUIT='1')
            if selection:
                group_env['ALCOVE_FULLSCREEN_COMMAND_CASES'] = ','.join(ordinary)
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
        for name in selected_layout:
            layout_env = dict(env, ALCOVE_FULLSCREEN_COMMAND_CASES=name)
            layout_env.pop('ALCOVE_FULLSCREEN_COMMAND_GROUP', None)
            print('FULLSCREEN_LAYOUT_PROCESS_STARTED', name, flush=True)
            try:
                result = subprocess.run([str(executable)], cwd=ROOT, env=layout_env,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=325)
                print(result.stdout[:2_000_000], end='', flush=True)
                cycles = result.stdout.count('AttributeGraph: cycle detected')
                print('FULLSCREEN_LAYOUT_CYCLES', name, cycles, flush=True)
                if result.returncode != 0 or cycles != 0 or len(result.stdout) > 2_000_000:
                    failed.append(name)
                    print('FULLSCREEN_LAYOUT_PROCESS_FAILED', name, 'exit', result.returncode, 'cycles', cycles, flush=True)
                else:
                    print('FULLSCREEN_LAYOUT_PROCESS_PASSED', name, flush=True)
            except subprocess.TimeoutExpired as error:
                failed.append(name)
                output = error.stdout or b''
                print(output.decode(errors='replace')[:2_000_000] if isinstance(output, bytes) else output[:2_000_000], flush=True)
                print('FULLSCREEN_LAYOUT_PROCESS_FAILED', name, 'timeout', flush=True)
        for name in selected_quits:
            with tempfile.TemporaryDirectory(prefix='owned-quit-', dir=OUT) as scratch:
                child_env = dict(env, ALCOVE_FULLSCREEN_COMMAND_CASES=name, ALCOVE_FULLSCREEN_QUIT_ROOT=scratch)
                child_env.pop('ALCOVE_FULLSCREEN_COMMAND_GROUP', None)
                child_env.pop('ALCOVE_FULLSCREEN_SKIP_QUIT', None)
                print('FULLSCREEN_QUIT_PROCESS_STARTED', name, flush=True)
                pid = None
                try:
                    print('FULLSCREEN_STAGE', executable.name, 'actual native Quit', flush=True)
                    process = subprocess.Popen([str(executable)], cwd=ROOT, env=child_env)
                    pid = process.pid
                    try:
                        code = process.wait(timeout=325)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                        raise
                    if code != 0:
                        raise subprocess.CalledProcessError(code, [str(executable)])
                    result = json.loads((Path(scratch) / 'quit-result.json').read_text())
                    assert result['formatVersion'] == 1 and result['case'] == name
                    assert type(result['pid']) is int and result['pid'] == pid
                    assert result['success'] is True and result['failures'] == 0 and result['checks'] > 0
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError, KeyError, AssertionError) as error:
                    failed.append(name)
                    print('FULLSCREEN_QUIT_PROCESS_FAILED', name, type(error).__name__, flush=True)
                finally:
                    cleanup_env = dict(env, ALCOVE_FULLSCREEN_QUIT_CLEANUP='1', ALCOVE_FULLSCREEN_QUIT_PID=str(pid or 0))
                    try:
                        command([str(executable)], timeout=325, env=cleanup_env)
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                        failed.append(name + '-cleanup')
                        print('FULLSCREEN_QUIT_PROCESS_CLEANUP_FAILED', name, type(error).__name__, flush=True)
                if name not in failed and name + '-cleanup' not in failed:
                    private = name.startswith('private-')
                    remainder = name[8:] if private else name
                    quick = remainder.startswith('quick-')
                    kind = remainder[6:] if quick else remainder
                    print('FULLSCREEN_COMMAND_CASE_COMPLETED', kind, 'private', str(private).lower(), 'quick', str(quick).lower(), flush=True)
                    print('FULLSCREEN_QUIT_PROCESS_EXITED', name, '0', flush=True)
        if failed:
            raise RuntimeError('Native fullscreen groups failed: ' + ', '.join(failed))
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        print('FULLSCREEN_SERVER_VIDEO_REQUESTS', media_requests, flush=True)


if __name__ == '__main__':
    main()
