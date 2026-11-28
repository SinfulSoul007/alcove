from pathlib import Path
import os,subprocess,uuid,plistlib,json,shutil,hashlib
assert os.environ.get("GITHUB_ACTIONS")=="true", "Hosted disposable CI only"
root=Path.cwd();out=root/".build/fullscreen/keychain-interaction";out.mkdir(parents=True,exist_ok=True)
work=root/".build/owned-keychain-interaction";work.mkdir(exist_ok=True)
identifier="dev.alcove.owned-keychain-probe."+uuid.uuid4().hex
sdk=subprocess.check_output(["xcrun","--show-sdk-path"],text=True).strip()
arch=subprocess.check_output(["uname","-m"],text=True).strip()
source=root/"Sources/Browser/MetadataKey.swift"
translated=subprocess.run(["sysctl","-n","sysctl.proc_translated"],capture_output=True,text=True)
assert translated.stdout.strip()!="1", "Actual native CPU execution required"
report={"sdk":sdk,"os":subprocess.check_output(["sw_vers"],text=True),"namespace":identifier,"sourceSHA256":hashlib.sha256(source.read_bytes()).hexdigest(),"scope":"Two owned ad hoc binaries at the same bundle path, exact product MetadataKey.load, disposable unique probe item only. No publisher key, user key or signing identity accessed. Legacy UI setting applies only inside one probe process and is restored. No trust/TCC/Gatekeeper settings changed.","architecture":arch,"observations":{}}
builds={}
for phase in ["A","B"]:
 app=work/phase/"Owned Keychain Probe.app";mac=app/"Contents/MacOS";mac.mkdir(parents=True,exist_ok=True)
 (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":identifier,"CFBundleExecutable":"OwnedKeychainProbe","CFBundleName":"Owned Keychain Probe","CFBundleVersion":phase,"CFBundlePackageType":"APPL","LSUIElement":True,"LSMinimumSystemVersion":"14.0"}))
 subprocess.run(["xcrun","swiftc","-sdk",sdk,"-target",arch+"-apple-macosx14.0","-module-cache-path",str(work/"cache"),"-parse-as-library","-DPROBE_"+phase,str(source),"scripts/OwnedKeychainInteractionProbe.swift","-o",str(mac/"OwnedKeychainProbe")],check=True)
 subprocess.run(["codesign","--force","--sign","-",str(app)],check=True)
 subprocess.run(["codesign","--verify","--strict",str(app)],check=True)
 signature=subprocess.run(["codesign","-d","-r-",str(app)],capture_output=True,text=True,check=True)
 report.setdefault("designatedRequirements",{})[phase]=signature.stdout+signature.stderr
 builds[phase]=app
assert report["designatedRequirements"]["A"]!=report["designatedRequirements"]["B"]
active=work/"active/Owned Keychain Probe.app"
def run(phase,mode,timeout=7):
 if active.exists():shutil.rmtree(active)
 active.parent.mkdir(exist_ok=True);shutil.copytree(builds[phase],active)
 exe=active/"Contents/MacOS/OwnedKeychainProbe"
 try:
  p=subprocess.run([str(exe),mode],capture_output=True,text=True,timeout=timeout,check=True)
  (out/(phase+"-"+mode+".log")).write_text(p.stdout+p.stderr)
  line=next((s for s in p.stdout.splitlines() if s.startswith("OWNED_KEYCHAIN_PROBE_RESULT ")),None)
  value=json.loads(line.split(" ",1)[1]) if line else {"cleanupOutput":p.stdout.strip()}
 except subprocess.TimeoutExpired as e:
  value={"timedOut":True,"timeoutSeconds":timeout,"ownedChildKilledByTimeout":True}
  (out/(phase+"-"+mode+".log")).write_bytes((e.stdout or b"")+(e.stderr or b""))
 report["observations"][phase+"-"+mode]=value
 print(phase,mode,json.dumps(value),flush=True);return value
created=False
try:
 first=run("A","create",15)
 assert first.get("status")==0 and first.get("bytes")==32
 created=True
 for mode in ["read","read-or-create"]:
  changed = run("B",mode)
  assert changed.get("status") in [-25293,-25308] and changed.get("seconds",100) < 2 and changed.get("bytes") == 0, "Changed ad hoc build must fail promptly without reading or replacing the protected item"
 interactive=run("A","interactive-owned-read")
 assert interactive.get("status")==0 and interactive.get("ownedRandomKeySHA256")==first["ownedRandomKeySHA256"], "Explicit interaction path must still read its creator's own item"
 for phase,mode in [("A","create"),("B","read"),("B","read-or-create"),("A","interactive-owned-read")]:
  log=(out/(phase+"-"+mode+".log")).read_text()
  assert "OWNED_KEYCHAIN_UI_POLICY_RESTORED 0 0 true" in log, "Product call must restore its process-local UI policy on success and failure"
 report["noninteractiveCrossBuildReturnedPromptly"] = True
 report["processLocalUIPolicyRestored"] = True
 again=run("A","read")
 assert again.get("status")==0 and again.get("ownedRandomKeySHA256")==first["ownedRandomKeySHA256"], "Original creator must retain exact original own random item"
 report["originalOwnKeyPreserved"]=True
finally:
 if created:run("A","delete")
 (out/"probe-result.json").write_text(json.dumps(report,indent=2)+"\n")
print("Owned Keychain diagnostic observations saved; this is not a shipping-browser fix claim.")
