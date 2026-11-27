"""Corresponding-source archive integrity and intact notice publication."""
import importlib
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


class SourceNoticeChecks(unittest.TestCase):
    def setUp(self):
        try:
            self.module = importlib.import_module('source_notices')
        except ModuleNotFoundError:
            self.fail('Corresponding-source verifier is missing')
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root/'upstream'; self.repo.mkdir()
        self.files = {'LICENSE': b'Original upstream license\nDo not remove this notice.\n',
                      'Source/main.c': b'int main(void) { return 0; }\n',
                      'Source/run': b'#!/bin/sh\nexit 0\n'}
        for name, data in self.files.items():
            path = self.repo/name; path.parent.mkdir(exist_ok=True, parents=True); path.write_bytes(data)
        (self.repo/'Source/run').chmod(0o755)
        (self.repo/'Source/license-link').symlink_to('../LICENSE')
        self.git('init', '--quiet'); self.git('add', '.')
        self.git('-c','user.name=Source Test','-c','user.email=source@example.invalid','commit','--quiet','-m','source fixture')
        self.revision = self.git('rev-parse','HEAD').strip()
        self.prefix = 'WebKit-'+self.revision

    def git(self, *args):
        return subprocess.check_output(['git','-C',str(self.repo),*args], text=True)

    def archive(self, *, changed=None, omitted=(), extra=(), mode=None, duplicate=False, link=None):
        archive = self.root/'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name, original in self.files.items():
                if name in omitted: continue
                data = (changed or {}).get(name, original)
                item = tarfile.TarInfo(self.prefix+'/'+name); item.size = len(data)
                item.mode = mode if mode is not None and name == 'Source/run' else (0o755 if name == 'Source/run' else 0o644)
                tar.addfile(item, io.BytesIO(data))
                if duplicate and name == 'LICENSE': tar.addfile(item, io.BytesIO(data))
            item = tarfile.TarInfo(self.prefix+'/Source/license-link')
            item.type = tarfile.SYMTYPE; item.linkname = link or '../LICENSE'; item.mode = 0o777
            tar.addfile(item)
            for name in extra:
                item = tarfile.TarInfo(name); item.size = 4; item.mode = 0o644
                tar.addfile(item, io.BytesIO(b'evil'))
        return archive

    def test_preserves_license_bytes_and_publishes_complete_source(self):
        archive = self.archive(); out = self.root/'published'
        receipt = self.module.prepare_source_notices(archive, self.repo, self.revision, out)
        self.assertEqual((out/'notices/LICENSE').read_bytes(), self.files['LICENSE'])
        self.assertEqual((out/'WebKit-source.tar.gz').read_bytes(), archive.read_bytes())
        self.assertEqual(receipt['sourceMembers'], 4)
        self.assertEqual(receipt['revision'], self.revision)
        self.assertFalse(receipt['nativeAppQualified'])
        self.assertEqual(receipt['notices'][0]['path'], 'LICENSE')
        self.assertTrue((out/'source-notices.json').is_file())

    def test_changed_source_is_rejected_without_publication(self):
        out = self.root/'published'
        with self.assertRaisesRegex(ValueError, 'blob|source bytes'):
            self.module.prepare_source_notices(self.archive(changed={'Source/main.c': b'changed'}), self.repo, self.revision, out)
        self.assertFalse(out.exists())

    def test_missing_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'missing|inventory'):
            self.module.verify_source_archive(self.archive(omitted=('Source/main.c',)), self.repo, self.revision)

    def test_changed_executable_mode_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'mode'):
            self.module.verify_source_archive(self.archive(mode=0o644), self.repo, self.revision)

    def test_changed_link_target_is_rejected_without_following_it(self):
        with self.assertRaisesRegex(ValueError, 'blob|link'):
            self.module.verify_source_archive(self.archive(link='/etc/passwd'), self.repo, self.revision)

    def test_duplicate_archive_member_is_rejected(self):
        with self.assertRaisesRegex(ValueError, '[Dd]uplicate'):
            self.module.verify_source_archive(self.archive(duplicate=True), self.repo, self.revision)

    def test_extra_and_escaping_paths_are_rejected(self):
        for name in (self.prefix+'/extra', self.prefix+'/../outside', '/absolute'):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'member|path|inventory'):
                self.module.verify_source_archive(self.archive(extra=(name,)), self.repo, self.revision)

    def test_existing_output_is_preserved(self):
        out = self.root/'published'; out.mkdir(); (out/'keep').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'destination'):
            self.module.prepare_source_notices(self.root/'missing', self.repo, self.revision, out)
        self.assertEqual((out/'keep').read_bytes(), b'keep')

    def test_unknown_revision_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'revision'):
            self.module.verify_source_archive(self.archive(), self.repo, '0'*40)

    def test_hardlink_cannot_substitute_for_source(self):
        archive = self.archive()
        with tarfile.open(archive, 'r:gz') as original:
            members = [(i, original.extractfile(i).read() if i.isfile() else None) for i in original]
        with tarfile.open(archive, 'w:gz') as tar:
            for item, data in members:
                if item.name.endswith('/Source/main.c'):
                    item.type = tarfile.LNKTYPE; item.linkname = self.prefix+'/LICENSE'; item.size = 0; data = None
                tar.addfile(item, io.BytesIO(data) if data is not None else None)
        with self.assertRaisesRegex(ValueError, 'type|regular'):
            self.module.verify_source_archive(archive, self.repo, self.revision)

    def test_pinned_package_rejects_unknown_wrapper_before_output(self):
        out = self.root/'engine-source'
        with self.assertRaisesRegex(ValueError, 'source revision'):
            self.module.prepare_engine_source(self.archive(), self.repo, self.root/'missing-runtime', out)
        self.assertFalse(out.exists())

    def test_pinned_package_preserves_existing_output(self):
        out = self.root/'engine-source'; out.mkdir(); (out/'keep').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'destination'):
            self.module.prepare_engine_source(self.root/'missing', self.repo, self.root/'missing-runtime', out)
        self.assertEqual((out/'keep').read_bytes(), b'keep')

    def test_source_archive_preserves_git_bytes_despite_export_and_eol_attributes(self):
        try:
            writer = importlib.import_module('source_archive')
        except ModuleNotFoundError:
            self.fail('Raw Git source archive writer is missing')
        (self.repo/'.gitattributes').write_bytes(b'*.bat text eol=crlf\nSource/main.c export-ignore\nLICENSE export-subst\n')
        (self.repo/'Source/build.bat').write_bytes(b'echo source\n')
        (self.repo/'LICENSE').write_bytes(b'Original notice $Format:%H$\n')
        self.git('add','.'); self.git('-c','user.name=Source Test','-c','user.email=source@example.invalid','commit','--quiet','-m','export attributes')
        revision = self.git('rev-parse','HEAD').strip()
        archive = self.root/'raw-source.tar.gz'
        writer.create_source_archive(self.repo, revision, archive)
        receipt = self.module.verify_source_archive(archive, self.repo, revision)
        self.assertEqual(receipt['sourceMembers'], 6)
        with tarfile.open(archive,'r:gz') as tar:
            prefix = 'WebKit-'+revision+'/'
            self.assertEqual(tar.extractfile(prefix+'LICENSE').read(), b'Original notice $Format:%H$\n')
            self.assertEqual(tar.extractfile(prefix+'Source/build.bat').read(), b'echo source\n')
            self.assertEqual(tar.extractfile(prefix+'Source/main.c').read(), self.files['Source/main.c'])
            self.assertEqual(tar.getmember(prefix+'Source/run').mode, 0o755)

    def test_source_archive_writer_preserves_existing_destination(self):
        try: writer = importlib.import_module('source_archive')
        except ModuleNotFoundError: self.fail('Raw Git source archive writer is missing')
        archive = self.root/'keep.tar.gz'; archive.write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'destination'):
            writer.create_source_archive(self.repo, self.revision, archive)
        self.assertEqual(archive.read_bytes(), b'keep')

    def test_patch_recipe_reconstructs_exact_producer_diff_without_worktree_changes(self):
        original = (self.repo/'Source/main.c').read_bytes()
        (self.repo/'Source/main.c').write_bytes(b'int main(void) { return 2; }\n')
        expected = subprocess.check_output(['git','-C',str(self.repo),'diff','--binary'])
        (self.repo/'Source/main.c').write_bytes(original)
        patches = []
        for before, after in ((0,1),(1,2)):
            p = self.root/('step-'+str(after)+'.patch')
            p.write_text('diff --git a/Source/main.c b/Source/main.c\n--- a/Source/main.c\n+++ b/Source/main.c\n@@ -1 +1 @@\n-int main(void) { return '+str(before)+'; }\n+int main(void) { return '+str(after)+'; }\n')
            patches.append(p)
        actual = self.module.verify_modified_source(self.repo, self.revision, patches, hashlib.sha256(expected).hexdigest())
        self.assertEqual(actual, expected)
        self.assertEqual((self.repo/'Source/main.c').read_bytes(), original)
        self.assertEqual(self.git('status','--porcelain'), '')
        with self.assertRaisesRegex(ValueError, 'patch'):
            self.module.verify_modified_source(self.repo, self.revision, list(reversed(patches)), hashlib.sha256(expected).hexdigest())

    def test_patch_recipe_rejects_different_expected_final_source(self):
        with self.assertRaisesRegex(ValueError, 'source diff'):
            self.module.verify_modified_source(self.repo, self.revision, [], '0'*64)

    def test_bare_source_uses_pinned_attributes_for_producer_diff(self):
        original = b'@implementation Fixture\n\n- (void)change {\n'+b'    // retained context\n'*10+b'    int value = 0;\n}\n@end\n'
        (self.repo/'Source/main.c').write_bytes(original)
        (self.repo/'.gitattributes').write_text('Source/main.c diff=objc\n')
        self.git('add','.'); self.git('-c','user.name=Source Test','-c','user.email=source@example.invalid','commit','--quiet','-m','producer diff attributes')
        revision = self.git('rev-parse','HEAD').strip()
        (self.repo/'Source/main.c').write_bytes(original.replace(b'value = 0',b'value = 1'))
        expected = subprocess.check_output(['git','-C',str(self.repo),'diff','--binary'])
        (self.repo/'Source/main.c').write_bytes(original)
        source_patch = self.root/'objc.patch'; source_patch.write_bytes(expected)
        bare = self.root/'bare.git'
        subprocess.run(['git','clone','--bare','--quiet',str(self.repo),str(bare)],check=True)
        self.assertEqual(self.module.verify_modified_source(bare,revision,[source_patch],hashlib.sha256(expected).hexdigest()), expected)

    def test_published_source_verifies_after_moving(self):
        out = self.root/'published'
        expected = self.module.prepare_source_notices(self.archive(),self.repo,self.revision,out)
        moved = self.root/'moved'; out.rename(moved)
        self.assertEqual(self.module.verify_prepared_source_notices(moved,self.repo,self.revision), expected)

    def test_changed_notice_cannot_be_authorized_by_its_own_receipt(self):
        import json
        out = self.root/'published'
        self.module.prepare_source_notices(self.archive(),self.repo,self.revision,out)
        changed = b'Replaced original notice\n'; (out/'notices/LICENSE').write_bytes(changed)
        metadata = out/'source-notices.json'; receipt = json.loads(metadata.read_text())
        receipt['notices'][0].update(bytes=len(changed),sha256=hashlib.sha256(changed).hexdigest())
        metadata.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError,'receipt|notice'):
            self.module.verify_prepared_source_notices(out,self.repo,self.revision)

    def test_missing_notice_and_unlisted_source_files_are_rejected(self):
        for kind in ('missing','extra'):
            with self.subTest(kind=kind):
                out = self.root/kind
                self.module.prepare_source_notices(self.archive(),self.repo,self.revision,out)
                if kind == 'missing': (out/'notices/LICENSE').unlink()
                else: (out/'unlisted-executable').write_bytes(b'extra')
                with self.assertRaisesRegex(ValueError,'inventory|notice'):
                    self.module.verify_prepared_source_notices(out,self.repo,self.revision)

    def test_symbolic_notice_is_rejected_even_with_original_bytes(self):
        out = self.root/'published'
        self.module.prepare_source_notices(self.archive(),self.repo,self.revision,out)
        notice = out/'notices/LICENSE'; notice.unlink(); notice.symlink_to(self.repo/'LICENSE')
        with self.assertRaisesRegex(ValueError,'link|type|regular'):
            self.module.verify_prepared_source_notices(out,self.repo,self.revision)

    def test_runtime_source_binding_requires_actual_frameworks(self):
        with self.assertRaisesRegex(ValueError,'regular|framework'):
            self.module.verify_engine_framework_sources(self.root/'missing-runtime')

    def test_runtime_source_binding_rejects_existing_changed_frameworks(self):
        runtime = self.root/'runtime'
        for name in ('JavaScriptCore','WebCore','WebKit'):
            path = runtime/(name+'.framework')/'Versions/A'/name
            path.parent.mkdir(parents=True);path.write_bytes(b'Changed framework bytes')
        with self.assertRaisesRegex(ValueError,'framework differs'):
            self.module.verify_engine_framework_sources(runtime)
