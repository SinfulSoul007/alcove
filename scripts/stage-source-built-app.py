from pathlib import Path
import os,json,hashlib,subprocess,plistlib
assert os.environ.get("GITHUB_ACTIONS")=="true"
root=Path.cwd();source=root/".build/update-candidate/Alcove.app";app=Path.home()/"Applications/Alcove.app"
assert not app.exists() and not app.is_symlink()
app.parent.mkdir(exist_ok=True);subprocess.run(["ditto",str(source),str(app)],check=True)
subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True)
assert (source/"Contents/MacOS/Alcove").read_bytes()==(app/"Contents/MacOS/Alcove").read_bytes()
info=plistlib.loads((app/"Contents/Info.plist").read_bytes());assert info["CFBundleIdentifier"]=="dev.openbrowser.mac" and info["CFBundleShortVersionString"]=="0.22.1" and info["CFBundleVersion"]=="34"
with open(os.environ["GITHUB_ENV"],"a") as f:f.write("ALCOVE_INSTALLED_APP="+str(app)+"\nALCOVE_INSTALLED_EVIDENCE="+str(root/".build/fullscreen/installed")+"\n")
print("Staged unchanged source-built0.22.1 normal app; not final universal installer")
