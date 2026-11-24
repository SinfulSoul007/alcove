#!/usr/bin/env python3
"""Run the actual runtime-composition CLI on owned ZIP/tar fixtures."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

HELPER=Path(__file__).with_name('prepare-jsc-runtime.py')
JSC='JavaScriptCore.framework/Versions/A/JavaScriptCore'
WEBKIT='WebKit.framework/Versions/A/WebKit'
CORE='WebCore.framework/Versions/A/WebCore'
PATCH=b'diff --git a/Source/JavaScriptCore/runtime/JSGlobalObject.cpp b/Source/JavaScriptCore/runtime/JSGlobalObject.cpp\n--- a/Source/JavaScriptCore/runtime/JSGlobalObject.cpp\n+++ b/Source/JavaScriptCore/runtime/JSGlobalObject.cpp\n@@ -1 +1 @@\n-old\n+new\n'
PATCH += b'diff --git a/Source/JavaScriptCore/runtime/JSPromisePrototype.cpp b/Source/JavaScriptCore/runtime/JSPromisePrototype.cpp\n--- a/Source/JavaScriptCore/runtime/JSPromisePrototype.cpp\n+++ b/Source/JavaScriptCore/runtime/JSPromisePrototype.cpp\n@@ -1 +1 @@\n-old\n+new\n'
def sha(data):return hashlib.sha256(data).hexdigest()

class RuntimeChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='alcove-jsc-runtime-check-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.patches=self.root/'patches';self.patches.mkdir()
        (self.patches/'prior.patch').write_bytes(b'prior\n');(self.patches/'jsc.patch').write_bytes(PATCH)
        self.entries=[(JSC,b'old-jsc','file'),(WEBKIT,b'unchanged-webkit','file'),(CORE,b'unchanged-core','file'),
                      ('WebKit.framework/WebKit','Versions/A/WebKit','symlink'),
                      ('DerivedSources/JavaScriptCore/stale.h',b'old-generated','file'),
                      ('DerivedSources/JavaScriptCore/build-host','/outside','symlink')]
        self.contract={'formatVersion':1,'artifactID':17,'wrapperCommit':'1'*40,'webkitRevision':'2'*40,
                       'patches':{'prior.patch':sha(b'prior\n')},
                       'additionalPatch':{'name':'jsc.patch','sha256':sha(PATCH),'paths':['Source/JavaScriptCore/runtime/JSGlobalObject.cpp','Source/JavaScriptCore/runtime/JSPromisePrototype.cpp']},
                       'retainedRoots':['WebKit.framework','WebCore.framework'],
                       'retainedBinaries':{WEBKIT:sha(b'unchanged-webkit'),CORE:sha(b'unchanged-core')},
                       'oldJavaScriptCoreSHA256':sha(b'old-jsc')}
        self.archive=self.root/'baseline.zip';self.contract_path=self.root/'contract.json';self.write_archive()
        self.control=self.root/'control';r=self.prepare(self.control);self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.control/WEBKIT).read_bytes(),b'unchanged-webkit')
    def write_archive(self,metadata=None):
        stream=io.BytesIO()
        with tarfile.open(fileobj=stream,mode='w:gz') as tar:
            for name,data,kind in self.entries:
                m=tarfile.TarInfo(name);m.mode=0o755 if name in [JSC,WEBKIT,CORE] else 0o644
                if kind=='symlink':m.type=tarfile.SYMTYPE;m.linkname=data;tar.addfile(m)
                elif kind=='hardlink':m.type=tarfile.LNKTYPE;m.linkname=data;tar.addfile(m)
                else:m.size=len(data);tar.addfile(m,io.BytesIO(data))
        runtime=stream.getvalue();self.contract['runtimeSHA256']=sha(runtime)
        payload={'Alcove-WebKitRuntime.tar.gz':runtime,'AlcoveSource.txt':(self.contract['wrapperCommit']+'\n').encode(),
                 'WebKitSource.txt':(self.contract['webkitRevision']+'\n').encode(),
                 'PatchChecksums.txt':(sha(b'prior\n')+'  diagnostics/prior.patch\n').encode(),
                 'SHA256SUMS.txt':(sha(runtime)+'  Alcove-WebKitRuntime.tar.gz\n').encode()}
        payload.update(metadata or {})
        with zipfile.ZipFile(self.archive,'w') as package:
            for name,data in payload.items():package.writestr(name,data)
        self.contract['archiveSHA256']=sha(self.archive.read_bytes());self.save_contract()
    def save_contract(self):self.contract_path.write_text(json.dumps(self.contract))
    def command(self,mode,destination):
        args=[sys.executable,str(HELPER),mode,'--contract',str(self.contract_path),'--destination',str(destination)]
        if mode=='prepare':args+=['--archive',str(self.archive),'--patch-directory',str(self.patches)]
        return subprocess.run(args,capture_output=True,text=True)
    def prepare(self,destination):return self.command('prepare',destination)
    def test_excludes_old_jsc_and_generated_sources(self):
        self.assertFalse((self.control/'JavaScriptCore.framework').exists());self.assertFalse((self.control/'DerivedSources').exists())
        self.assertTrue((self.control/WEBKIT).stat().st_mode&0o100)
        self.assertEqual((self.control/'WebKit.framework/WebKit').resolve(),(self.control/WEBKIT).resolve())
    def test_requires_new_jsc_and_keeps_other_binaries(self):
        self.assertNotEqual(self.command('verify',self.control).returncode,0)
        path=self.control/JSC;path.parent.mkdir(parents=True);path.write_bytes(b'new-jsc')
        self.assertEqual(self.command('verify',self.control).returncode,0)
        (self.control/CORE).write_bytes(b'changed-core')
        self.assertNotEqual(self.command('verify',self.control).returncode,0)
    def test_keeps_safe_cross_framework_sibling_link(self):
        self.entries += [('libShared.dylib',b'unchanged-shared','file'),('WebKit.framework/Versions/A/Frameworks/libShared.dylib','../../../../libShared.dylib','symlink')]
        self.contract['retainedRoots'].append('libShared.dylib');self.write_archive();destination=self.root/'sibling'
        result=self.prepare(destination);self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((destination/'WebKit.framework/Versions/A/Frameworks/libShared.dylib').resolve(),(destination/'libShared.dylib').resolve())
    def test_rejects_chain_that_escapes_after_resolution(self):
        self.entries += [('WebCore.framework/Versions/A/deep','../../../WebKit.framework','symlink'),('WebCore.framework/escape','Versions/A/deep/../../outside','symlink')]
        self.write_archive();destination=self.root/'chain'
        self.assertNotEqual(self.prepare(destination).returncode,0);self.assertFalse(destination.exists())
    def test_package_excludes_build_tools(self):
        path=self.control/JSC;path.parent.mkdir(parents=True);path.write_bytes(b'new-jsc')
        for name in ['jsc','testb3','LLIntOffsetsExtractor']:(self.control/name).write_bytes(b'owned-build-tool')
        output=self.root/'runtime.tar.gz'
        result=subprocess.run([sys.executable,str(HELPER),'package','--contract',str(self.contract_path),'--destination',str(self.control),'--output',str(output)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        with tarfile.open(output) as archive:
            roots={m.name.split('/',1)[0] for m in archive}
        self.assertEqual(roots,set(self.contract['retainedRoots'])|{'JavaScriptCore.framework','AlcoveJavaScriptCoreBaseline.json','AlcoveJavaScriptCoreVerification.json'})
    def test_rejects_reused_jsc_binary(self):
        path=self.control/JSC;path.parent.mkdir(parents=True);path.write_bytes(b'old-jsc')
        self.assertNotEqual(self.command('verify',self.control).returncode,0)
    def test_existing_destination_preserved(self):
        (self.control/'keep').write_text('owned')
        self.assertNotEqual(self.prepare(self.control).returncode,0);self.assertEqual((self.control/'keep').read_text(),'owned')
    def test_rejects_bad_provenance_atomically(self):
        self.write_archive({'AlcoveSource.txt':b'wrong\n'});dest=self.root/'bad'
        self.assertNotEqual(self.prepare(dest).returncode,0);self.assertFalse(dest.exists())
    def test_rejects_changed_patch(self):
        (self.patches/'jsc.patch').write_bytes(PATCH+b'changed\n');dest=self.root/'bad'
        self.assertNotEqual(self.prepare(dest).returncode,0);self.assertFalse(dest.exists())
    def test_rejects_traversal(self):
        self.entries.append(('../escape',b'unsafe','file'));self.write_archive();dest=self.root/'bad'
        self.assertNotEqual(self.prepare(dest).returncode,0);self.assertFalse(dest.exists());self.assertFalse((self.root/'escape').exists())
    def test_rejects_duplicate_casefold_names(self):
        self.entries += [('WebCore.framework/DATA',b'first','file'),('WebCore.framework/data',b'second','file')];self.write_archive()
        self.assertNotEqual(self.prepare(self.root/'bad').returncode,0)
    def test_rejects_retained_unsafe_links(self):
        for kind,target in [('symlink','/outside'),('hardlink',CORE)]:
            with self.subTest(kind=kind):
                self.entries.append(('WebCore.framework/unsafe',target,kind));self.write_archive()
                self.assertNotEqual(self.prepare(self.root/'bad').returncode,0);self.entries.pop()
    def test_rejects_parent_links_and_unreviewed_roots(self):
        for entries in [[('WebCore.framework/link','Versions','symlink'),('WebCore.framework/link/escape',b'x','file')],[('Unreviewed.framework/payload',b'x','file')]]:
            with self.subTest(entries=entries):
                original=list(self.entries);self.entries+=entries;self.write_archive()
                self.assertNotEqual(self.prepare(self.root/'bad').returncode,0);self.entries=original

if __name__=='__main__':unittest.main()
