"""Diagnostic-only: real menu shortcuts in owned production Quick Browse windows."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / '.build' / 'fullscreen'
out.mkdir(parents=True, exist_ok=True)
manifest = {
    str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
    for folder in ('Browser', 'BrowserCore')
    for p in sorted((root / 'Sources' / folder).glob('*.swift'))
}
(out / 'quick-inputs.json').write_text(json.dumps(manifest, indent=2) + '\n')
environment = dict(os.environ, ALCOVE_QUICK_FOCUS_COMPILE_ONLY='1')
subprocess.run(['bash', 'scripts/build.sh', 'quick-focus-test'], cwd=root,
               env=environment, check=True, timeout=1200)
executable = root / '.build' / 'manual' / os.uname().machine / 'quick-focus-checks'
environment.pop('ALCOVE_QUICK_FOCUS_COMPILE_ONLY')
environment['ALCOVE_OWNED_WINDOW_CAPTURE_DIR'] = str(out / 'owned-window-captures')
subprocess.run([str(executable)], cwd=root, env=environment, check=True, timeout=120)
