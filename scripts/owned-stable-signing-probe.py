from pathlib import Path
import os,subprocess,tempfile,secrets,uuid,plistlib,json,shutil,hashlib
assert os.environ.get("GITHUB_ACTIONS")=="true", "Disposable hosted diagnostic only"
root=Path.cwd();out=root/".build/fullscreen/stable-signing";out.mkdir(parents=True,exist_ok=True)
report={"scope":"INTERNAL QA EXPERIMENT ONLY. New temporary self-created signing certificate, owned unique probe namespace, no Apple identity claim. No System/user trust settings, Gatekeeper, TCC or preexisting item ACL changes. No publisher/user keys accessed. Apple advises against shipping self-signed apps; this is not a public distribution solution.","architecture":subprocess.check_output(["uname","-m"],text=True).strip(),"os":subprocess.check_output(["sw_vers"],text=True),"observations":{}}
source=root/"Sources/Browser/MetadataKey.swift";report["sourceSHA256"]=hashlib.sha256(source.read_bytes()).hexdigest()
class StageFailure(Exception):pass
with tempfile.TemporaryDirectory(prefix="alcove-owned-signing-") as temporary:
 work=Path(temporary);os.chmod(work,0o700);keychain=work/"owned-signing.keychain-db";password=secrets.token_urlsafe(40);env={**os.environ,"ALCOVE_OWNED_P12_PASSWORD":password}
 phase="initial";created=False;itemCreated=False;active=work/"active/Owned Keychain Probe.app";builds={}
 def command(name,args,private=False):
  global phase
  phase=name;p=subprocess.run(args,capture_output=True,text=True,env=env,timeout=30)
  if p.returncode:
   report["failedPhase"]=name;report["returnCode"]=p.returncode
   if not private:report["error"]=p.stderr.replace(password,"<temporary password>")[-1800:]
   raise StageFailure(name)
  return p.stdout+p.stderr
 def run(variant,mode):
  if active.exists():shutil.rmtree(active)
  active.parent.mkdir(exist_ok=True);shutil.copytree(builds[variant],active)
  p=subprocess.run([str(active/"Contents/MacOS/OwnedKeychainProbe"),mode],capture_output=True,text=True,timeout=8,env=env)
  log=p.stdout+p.stderr;(out/(variant+"-"+mode+".log")).write_text(log)
  assert p.returncode==0
  line=next(s for s in log.splitlines() if s.startswith("OWNED_KEYCHAIN_PROBE_RESULT "))
  value=json.loads(line.split(" ",1)[1]);report["observations"][variant+"-"+mode]=value
  print(variant,mode,"status",value["status"],"seconds",value["seconds"],flush=True);return value
 try:
  config=work/"openssl.cnf";config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=code_signing\nprompt=no\n[dn]\nCN=Alcove Owned Internal Signing Probe\n[code_signing]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n")
  command("create temporary certificate",["/usr/bin/openssl","req","-new","-x509","-newkey","rsa:3072","-nodes","-sha256","-days","2","-config",str(config),"-keyout",str(work/"private.pem"),"-out",str(work/"certificate.pem")],True)
  command("encode temporary PKCS12",["/usr/bin/openssl","pkcs12","-export","-inkey",str(work/"private.pem"),"-in",str(work/"certificate.pem"),"-out",str(work/"identity.p12"),"-passout","env:ALCOVE_OWNED_P12_PASSWORD"],True)
  command("create own temporary keychain",["/usr/bin/security","create-keychain","-p",password,str(keychain)],True);created=True
  command("unlock own temporary keychain",["/usr/bin/security","unlock-keychain","-p",password,str(keychain)],True)
  command("import only own identity",["/usr/bin/security","import",str(work/"identity.p12"),"-k",str(keychain),"-P",password,"-T","/usr/bin/codesign"],True)
  fingerprint=command("read own public certificate fingerprint",["/usr/bin/openssl","x509","-in",str(work/"certificate.pem"),"-noout","-fingerprint","-sha1"]).strip().split("=")[-1].replace(":","")
  report["publicCertificateSHA1"]=fingerprint
  identifier="dev.alcove.owned-keychain-probe."+uuid.uuid4().hex;sdk=subprocess.check_output(["xcrun","--show-sdk-path"],text=True).strip();arch=report["architecture"]
  for variant in ["A","B"]:
   app=work/variant/"Owned Keychain Probe.app";mac=app/"Contents/MacOS";mac.mkdir(parents=True)
   (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":identifier,"CFBundleExecutable":"OwnedKeychainProbe","CFBundleName":"Owned Keychain Probe","CFBundleVersion":variant,"CFBundlePackageType":"APPL","LSUIElement":True,"LSMinimumSystemVersion":"14.0"}))
   command("compile own variant"+variant,["xcrun","swiftc","-sdk",sdk,"-target",arch+"-apple-macosx14.0","-module-cache-path",str(work/"cache"),"-parse-as-library","-DPROBE_"+variant,str(source),"scripts/OwnedKeychainInteractionProbe.swift","-o",str(mac/"OwnedKeychainProbe")])
   command("sign own variant"+variant,["codesign","--force","--sign",fingerprint,"--keychain",str(keychain),"--timestamp=none","--options","runtime","--entitlements","scripts/Entitlements.plist",str(app)])
   command("verify own variant"+variant,["codesign","--verify","--deep","--strict",str(app)])
   details=command("inspect own variant"+variant,["codesign","-d","-r-",str(app)])
   requirement=next(s.strip().lstrip("#").strip() for s in details.splitlines() if "designated =>" in s)
   report.setdefault("designatedRequirements",{})[variant]=requirement
   report.setdefault("executables",{})[variant]=hashlib.sha256((mac/"OwnedKeychainProbe").read_bytes()).hexdigest();builds[variant]=app
  assert report["executables"]["A"]!=report["executables"]["B"]
  assert report["designatedRequirements"]["A"]==report["designatedRequirements"]["B"]
  first=run("A","create");assert first["status"]==0 and first["bytes"]==32;itemCreated=True
  second=run("B","read");assert second["status"]==0 and second["ownedRandomKeySHA256"]==first["ownedRandomKeySHA256"]
  assert "OWNED_KEYCHAIN_UI_POLICY_RESTORED 0 0 true" in (out/"B-read.log").read_text()
  report["sameIdentityDifferentBinaryKeyAccess"]=True;report["status"]="success"
 except StageFailure:report["status"]="unsupported without changing trust or policy"
 except Exception as error:
  report["status"]="failed diagnostic";report["failedPhase"]=phase;report["errorType"]=type(error).__name__
 finally:
  if itemCreated:
   if active.exists():shutil.rmtree(active)
   shutil.copytree(builds["A"],active)
   p=subprocess.run([str(active/"Contents/MacOS/OwnedKeychainProbe"),"delete"],capture_output=True,text=True,timeout=8,env=env)
   report["ownItemDeleted"]=p.returncode==0 and "OWNED_KEYCHAIN_PROBE_DELETE 0" in p.stdout
  if created:
   p=subprocess.run(["/usr/bin/security","delete-keychain",str(keychain)],capture_output=True,env=env)
   report["ownTemporarySigningKeychainDeleted"]=p.returncode==0
  (out/"stable-signing-result.json").write_text(json.dumps(report,indent=2)+"\n")
print("Internal stable-signing diagnostic",report["status"],"phase",report.get("failedPhase","complete"),flush=True)
print("No signing private key or identity archive is retained or uploaded. No public-distribution approval inferred.")
