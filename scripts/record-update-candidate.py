from pathlib import Path
import json,hashlib,plistlib,os,subprocess
source="fb3b90b2fc6be86fb4366979204a48e7eb9362e3"
root=Path.cwd();app=root/".build/update-candidate/Alcove.app";info=plistlib.loads((app/"Contents/Info.plist").read_bytes());assert info["CFBundleIdentifier"]=="dev.openbrowser.mac" and info["CFBundleShortVersionString"]=="0.22.1" and info["CFBundleVersion"]=="34"
subprocess.run(["git","diff","--exit-code",source,"HEAD","--","Sources","Resources","scripts/Info.plist","scripts/build.sh"],check=True)
evidence=root/".build/fullscreen/installed";evidence.mkdir(parents=True,exist_ok=True)
paths=subprocess.check_output(["git","ls-files","-z","Sources","Resources","scripts/Info.plist","scripts/build.sh"]).decode().split("\0");hashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths if p}
origin={"source":source,"diagnosticHead":subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip(),"version":"0.22.1","build":"34","bundleID":info["CFBundleIdentifier"],"appExecutableSHA256":hashlib.sha256((app/"Contents/MacOS/Alcove").read_bytes()).hexdigest(),"runtimeArchitecture":subprocess.check_output(["uname","-m"],text=True).strip(),"scope":"Source-built normal candidate app, same Source/Resources/Info/build script as declared source. Not the final full-CI universal installer. No runtime/key provider arguments injected.","inputSHA256":hashes}
(evidence/"candidate-source-build-origin.json").write_text(json.dumps(origin,indent=2)+"\n")
with open(os.environ["GITHUB_ENV"],"a") as f:f.write("ALCOVE_UPDATE_CANDIDATE_APP="+str(app)+"\n")
print("Recorded unchanged candidate app provenance",len(hashes),origin["runtimeArchitecture"])
