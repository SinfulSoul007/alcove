#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys,tarfile,tempfile,unittest
from pathlib import Path
HELPER=Path(__file__).with_name('package-built-engine.py')
class EntryRuntimePackagingChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.product=self.root/'products';self.product.mkdir()
        self.roots=['JavaScriptCore.framework','WebCore.framework','WebKit.framework']
        self.binaries={}
        for name in self.roots:
            leaf=name.removesuffix('.framework');path=self.product/name/'Versions/A'/leaf;path.parent.mkdir(parents=True);path.write_bytes(('owned-'+leaf).encode());path.chmod(0o755)
            (self.product/name/leaf).symlink_to('Versions/A/'+leaf);self.binaries[name]=path
        self.contract={'formatVersion':1,'webkitRevision':'a'*40,'runtimeRoots':self.roots,'patches':{'owned.patch':'b'*64}}
        self.manifest={'formatVersion':1,'webkitRevision':'a'*40,'wrapperCommit':'c'*40,'sdk':'26.5','patches':self.contract['patches'],'buildCommand':['owned source build'],'emptyProductsAtStart':True}
        self.contractFile=self.root/'roots.json';self.manifestFile=self.root/'manifest.json';self.output=self.root/'runtime.tar.gz';self.save()
    def save(self):
        self.contractFile.write_text(json.dumps(self.contract));self.manifestFile.write_text(json.dumps(self.manifest))
    def run_helper(self):
        return subprocess.run([sys.executable,str(HELPER),'--product',str(self.product),'--contract',str(self.contractFile),'--manifest',str(self.manifestFile),'--output',str(self.output)],capture_output=True,text=True)
    def test_packages_only_runtime_products(self):
        (self.product/'owned-unapproved').write_text('not a runtime product')
        (self.product/'WebCore.framework/owned.o').write_text('object')
        result=self.run_helper();self.assertEqual(result.returncode,0,result.stderr)
        with tarfile.open(self.output) as archive:
            names=archive.getnames();self.assertEqual({n.split('/')[0] for n in names},set(self.roots)|{'AlcoveEngineBuild.json'})
            self.assertNotIn('WebCore.framework/owned.o',names)
            record=json.load(archive.extractfile('AlcoveEngineBuild.json'))
            self.assertEqual(record['source'],self.manifest)
            for name,path in self.binaries.items():self.assertEqual(record['frameworkSHA256'][name],hashlib.sha256(path.read_bytes()).hexdigest())
    def test_missing_rebuilt_framework_is_refused(self):
        self.binaries['WebCore.framework'].unlink();self.assertNotEqual(self.run_helper().returncode,0);self.assertFalse(self.output.exists())
    def test_non_executable_framework_is_refused(self):
        self.binaries['JavaScriptCore.framework'].chmod(0o644);self.assertNotEqual(self.run_helper().returncode,0);self.assertFalse(self.output.exists())
    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b'keep owned output');self.assertNotEqual(self.run_helper().returncode,0);self.assertEqual(self.output.read_bytes(),b'keep owned output')
    def test_wrong_source_sdk_or_patch_is_refused(self):
        for key,value in [('webkitRevision','d'*40),('sdk','unknown'),('patches',{'owned.patch':'e'*64}),('emptyProductsAtStart',False)]:
            with self.subTest(key=key):
                original=self.manifest[key];self.manifest[key]=value;self.save();self.assertNotEqual(self.run_helper().returncode,0);self.assertFalse(self.output.exists());self.manifest[key]=original
    def test_absolute_link_is_refused(self):
        (self.product/'WebCore.framework/owned-link').symlink_to('/tmp/owned-absolute');self.assertNotEqual(self.run_helper().returncode,0);self.assertFalse(self.output.exists())
    def test_link_to_omitted_product_is_refused(self):
        (self.product/'DerivedSources').mkdir();(self.product/'DerivedSources/owned').write_text('owned generated input')
        (self.product/'WebCore.framework/owned-link').symlink_to('../DerivedSources/owned');self.assertNotEqual(self.run_helper().returncode,0);self.assertFalse(self.output.exists())
if __name__=='__main__':unittest.main()
