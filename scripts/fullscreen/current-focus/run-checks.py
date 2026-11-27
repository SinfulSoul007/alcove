from pathlib import Path
import subprocess,os,sys
port=Path('port').read_text().strip()
cases=['layout-normal-ready-focus-production','layout-normal-loading-focus-production','layout-private-ready-focus-production','layout-private-loading-focus-production','layout-normal-background-focus-production','layout-normal-empty-focus-production','layout-private-empty-focus-production','layout-normal-background-empty-focus-production','layout-private-background-empty-focus-production']
failed=False
for label,selection in [('combined',','.join(cases)),('fresh-private','layout-private-loading-focus-production')]:
 env=dict(os.environ,ALCOVE_FULLSCREEN_FIXTURE_URL='http://127.0.0.1:'+port+'/',ALCOVE_FULLSCREEN_COMMAND_CASES=selection)
 try:
  p=subprocess.run(['./website-fullscreen-checks'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
  Path(label+'.log').write_bytes(p.stdout)
  lines=p.stdout.decode(errors='replace').splitlines();cycles=sum('cycle detected' in s.lower() for s in lines)
  print('CURRENT_FOCUS_RESULT',label,'exit',p.returncode,'cycles',cycles,flush=True)
  print(p.stdout.decode(errors='replace'),flush=True)
  if p.returncode or cycles:failed=True
  if 'FULLSCREEN_ENVIRONMENT_UNAVAILABLE' in lines:break
 except subprocess.TimeoutExpired as e:
  Path(label+'.log').write_bytes(e.stdout or b'');print('CURRENT_FOCUS_TIMEOUT',label,flush=True);failed=True
sys.exit(1 if failed else 0)
