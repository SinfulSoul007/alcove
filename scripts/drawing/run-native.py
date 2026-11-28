"""Owned drawing integration witnesses; native execution requires VM or CI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compile-only', action='store_true')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--regressions', action='store_true')
    mode.add_argument('--window', action='store_true', help='Run the owned browser-window input and OS capture witness')
    args = parser.parse_args()
    if not args.compile_only and os.environ.get('GITHUB_ACTIONS') != 'true':
        model = subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip()
        if not model.startswith('VirtualMac'):
            raise SystemExit('Native drawing checks run only in the dedicated VirtualMac or hosted CI; use --compile-only here.')
    root = Path(__file__).resolve().parents[2]
    out = root / '.build' / 'drawing'
    evidence = root / '.build' / 'fullscreen'
    out.mkdir(parents=True, exist_ok=True); evidence.mkdir(parents=True, exist_ok=True)
    inputs = [p for kind in ('Browser', 'BrowserCore') for p in sorted((root / 'Sources' / kind).glob('*.swift'))]
    (evidence / 'drawing-inputs.json').write_text(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2) + '\n')
    sdk = os.environ.get('BROWSER_SDK') or subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    flags = ['-sdk', sdk, '-target', os.uname().machine + '-apple-macosx14.0', '-module-cache-path', str(out / 'cache'), '-warnings-as-errors']

    def command(values, timeout):
        print('DRAWING_COMMAND', ' '.join(map(str, values)), flush=True)
        subprocess.run(list(map(str, values)), cwd=root, check=True, timeout=timeout)

    core = [p for p in inputs if p.parent.name == 'BrowserCore']
    command(['xcrun', 'swiftc', *flags, '-emit-module', '-emit-library', '-enable-testing', '-module-name', 'BrowserCore', *core,
             '-o', out / 'libBrowserCore.dylib', '-emit-module-path', out / 'BrowserCore.swiftmodule'], 300)
    browser = [p for p in inputs if p.parent.name == 'Browser' and p.name != 'main.swift']
    groups = [
        ('values', [root / 'scripts/EaselDrawingCoreChecks.swift']),
        ('documents', [root / 'scripts/EaselDrawingDocumentChecks.swift']),
        ('gestures', [root / 'scripts/EaselDrawingGestureChecks.swift']),
        ('renderer', [root / 'Sources/Browser/EaselDrawingRenderer.swift', root / 'scripts/EaselDrawingRendererChecks.swift']),
        ('native', [*browser, root / 'scripts/EaselDrawingNativeChecks.swift']),
        ('stores', [*browser, root / 'scripts/EaselDrawingStoreChecks.swift']),
        ('interaction', [*browser, root / 'scripts/EaselDrawingInteractionChecks.swift']),
        ('toolbar', [*browser, root / 'scripts/EaselDrawingToolbarChecks.swift']),
    ]
    groups = [group for group in groups if group[0] in ('interaction', 'toolbar')]
    if args.window:
        groups = [('window', [*browser, root / 'scripts/EaselDrawingWindowChecks.swift'])]
        os.environ['ALCOVE_DRAWING_SCREENSHOT_DIR'] = str(evidence / 'drawing-snapshots')
    if args.regressions:
        for label, fixture, helpers in [
            ('old-canvas', 'EaselCanvasChecks', []),
            ('old-library', 'EaselLibraryChecks', []),
            ('old-pane', 'EaselPaneChecks', []),
            ('old-drafts', 'EaselDraftChecks', []),
            ('old-recovery', 'EaselDraftRecoveryChecks', []),
            ('old-tabs', 'EaselTabChecks', []),
            ('old-export-core', 'EaselExportCoreChecks', None),
            ('old-export-png', 'EaselExportRenderChecks', []),
            ('old-export-web', 'EaselExportWebsiteChecks', []),
            ('old-export-store', 'EaselExportStoreChecks', ['PageOutputFixtures']),
            ('old-ownership', 'WriterOwnershipChecks', []),
        ]:
            files = [] if helpers is None else [*browser, *[root / ('scripts/' + helper + '.swift') for helper in helpers]]
            groups.append((label, [*files, root / ('scripts/' + fixture + '.swift')]))
        shutil.copyfile(root / 'scripts/Fixtures/Easel16Bit.png', out / 'Easel16Bit.png')
    for folder, parent in [('ReaderAssets', root / 'Sources/Browser'), ('WebsiteProtection', root / 'Resources')]:
        shutil.copytree(parent / folder, out / folder, dirs_exist_ok=True)
    for label, files in groups:
        executable = out / ('drawing-' + label + '-checks')
        command(['xcrun', 'swiftc', *flags, '-parse-as-library', '-I', out, '-L', out, '-lBrowserCore',
                 '-Xlinker', '-rpath', '-Xlinker', '@executable_path', *files, '-o', executable], 1200)
        if not args.compile_only:
            command([executable], 120)
            print('DRAWING_GROUP_PASSED', label, flush=True)
    print('DRAWING_QUALIFICATION_FINISHED', 'compile-only' if args.compile_only else 'owned-native', flush=True)


if __name__ == '__main__':
    main()
