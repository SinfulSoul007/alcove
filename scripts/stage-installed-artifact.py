from pathlib import Path
import argparse,hashlib,json,os,plistlib,re,subprocess,sys,tempfile,zipfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
from release_package import stage_artifact
p=argparse.ArgumentParser();p.add_argument('--artifact',required=True,type=int);p.add_argument('--source',required=True);p.add_argument('--version',required=True);p.add_argument('--digest',required=True);a=p.parse_args()
assert a.artifact > 0 and re.fullmatch(r'[a-f0-9]{40}',a.source) and re.fullmatch(r'[a-f0-9]{64}',a.digest) and re.fullmatch(r'(?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)[.](?:0|[1-9][0-9]*)',a.version)
repo='SinfulSoul007/alcove'
def api(endpoint):return subprocess.check_output(['gh','api','repos/'+repo+'/'+endpoint])
meta=json.loads(api('actions/artifacts/'+str(a.artifact)));origin=meta['workflow_run'];run=json.loads(api('actions/runs/'+str(origin['id'])))
assert run['head_sha']==a.source and origin['head_sha']==a.source
assert run['path']=='.github/workflows/ci.yml' and run['status']=='completed' and run['conclusion']=='success'
assert run['repository']['full_name'].lower()==repo.lower() and run['head_repository']['id']==run['repository']['id']
assert origin['repository_id']==run['repository']['id'] and origin['head_repository_id']==run['repository']['id']
assert type(meta['size_in_bytes']) is int and 0 < meta['size_in_bytes'] <= 1024**3
assert meta['name']=='Alcove-universal-unsigned-preview' and not meta['expired'] and meta['digest']=='sha256:'+a.digest
out=Path('.build/installed');out.mkdir(parents=True,exist_ok=True)
archive=out/'artifact.zip';archive.write_bytes(api('actions/artifacts/'+str(a.artifact)+'/zip'))
assert archive.stat().st_size==meta['size_in_bytes'] and hashlib.sha256(archive.read_bytes()).hexdigest()==a.digest
stage_artifact(archive,meta,a.version,out/'dist')
zip_path=out/'dist'/('Alcove-'+a.version+'-universal-unsigned-preview.zip')
subprocess.run([sys.executable,'scripts/verify-package.py',str(zip_path)],check=True)
unpacked=out/'unpacked';unpacked.mkdir()
subprocess.run(['ditto','-x','-k',str(zip_path),str(unpacked)],check=True)
source=unpacked/'Alcove.app';app=Path.home()/'Applications'/'Alcove.app'
assert not app.exists() and not app.is_symlink()
app.parent.mkdir(exist_ok=True);subprocess.run(['ditto',str(source),str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict','--all-architectures',str(app)],check=True)
subprocess.run(['lipo',str(app/'Contents/MacOS/Alcove'),'-verify_arch','arm64','x86_64'],check=True)
info=plistlib.loads((app/'Contents/Info.plist').read_bytes());assert info['CFBundleShortVersionString']==a.version and info['CFBundleIdentifier']=='dev.openbrowser.mac'
evidence=Path('.build/fullscreen/installed');evidence.mkdir(parents=True,exist_ok=True)
receipt={'artifact':a.artifact,'artifactDigest':a.digest,'artifactBytes':archive.stat().st_size,'source':a.source,'run':run['id'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundleID':info['CFBundleIdentifier'],'appExecutableSHA256':hashlib.sha256((app/'Contents/MacOS/Alcove').read_bytes()).hexdigest(),'copyLocation':str(app),'universalSignatureVerified':True,'quarantine':'no attribute removed or settings changed; direct artifact copy is not a browser download'}
(evidence/'package-origin.json').write_text(json.dumps(receipt,indent=2)+'\n')
with open(os.environ['GITHUB_ENV'],'a') as f:f.write('ALCOVE_INSTALLED_APP='+str(app)+'\nALCOVE_INSTALLED_EVIDENCE='+str(evidence.resolve())+'\n')
print('Verified artifact and copied ordinary bundle:',a.artifact,a.source,a.version)
