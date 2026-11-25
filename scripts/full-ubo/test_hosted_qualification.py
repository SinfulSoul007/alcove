import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('hosted', Path(__file__).with_name('hosted-qualification.py'))
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)

class ConsumerChecks(unittest.TestCase):
    def test_source_run_rejects_foreign_failed_or_changed_head(self):
        run = {'id': hosted.RUN, 'status': 'completed', 'conclusion': 'success',
               'path': '.github/workflows/build-microtask-entry.yml', 'head_sha': hosted.WRAPPER, 'head_branch': hosted.BRANCH, 'event': 'push',
               'repository': {'id': hosted.REPOSITORY_ID, 'full_name': hosted.REPOSITORY},
               'head_repository': {'id': hosted.REPOSITORY_ID, 'full_name': hosted.REPOSITORY}}
        hosted.verify_run(run)
        for key, value in [('head_sha','0'*40),('conclusion','failure'),('event','pull_request'),('head_branch','main')]:
            candidate = dict(run, **{key:value})
            with self.assertRaises(ValueError): hosted.verify_run(candidate)
        candidate=copy.deepcopy(run);candidate['head_repository']['id']=1
        with self.assertRaises(ValueError): hosted.verify_run(candidate)

    def test_artifact_rejects_expiry_digest_and_identity_changes(self):
        item={'id':hosted.ARTIFACT,'name':hosted.ARTIFACT_NAME,'expired':False,
              'digest':'sha256:'+hosted.OUTER_SHA,'size_in_bytes':hosted.OUTER_BYTES,
              'workflow_run':{'id':hosted.RUN,'repository_id':hosted.REPOSITORY_ID,
                  'head_repository_id':hosted.REPOSITORY_ID,'head_sha':hosted.WRAPPER,'head_branch':hosted.BRANCH}}
        hosted.verify_artifact(item)
        for key,value in [('expired',True),('digest','sha256:'+'0'*64),('id',1),('size_in_bytes',1)]:
            with self.assertRaises(ValueError): hosted.verify_artifact(dict(item,**{key:value}))

    def test_positive_gate_rejects_partial_missing_controls_failure_and_early_exit(self):
        caps='UBO_NATIVE_CAPABILITIES '+json.dumps({'privacy':'object','idle':'function','updateEvent':'function','navigationTarget':'function'})+'\n'
        log='ACTUAL_WEBKIT_FRAMEWORK /verified/WebKit.framework\n'+caps*2
        for kind in ('zip','crx'): log+='UNMODIFIED_FULL_UBO_ASSET_FILTERING_PROVEN '+kind+'\n'
        log+='UNMODIFIED_FULL_UBO_INTEGRATED_FILTERING_PROVEN true\n'
        hosted.verify_positive_markers(log)
        for candidate in [log.replace('PROVEN crx','PROVEN omitted'),log.replace('"idle": "function"','"idle": "undefined"'),log+'UNMODIFIED_FULL_UBO_QUALIFICATION_FAILED error\n',log+'UBO_APPLICATION_LOOP_PREMATURE_EXIT\n',log+caps]:
            with self.assertRaises(ValueError): hosted.verify_positive_markers(candidate)

    def test_link_graph_refuses_noncanonical_dangling_and_escape(self):
        import tarfile
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);(root/'WebCore.framework/Versions/A').mkdir(parents=True)
            (root/'WebCore.framework/Versions/Current').symlink_to('A')
            (root/'WebCore.framework/Frameworks').symlink_to('Versions/Current/Frameworks')
            member=tarfile.TarInfo('WebCore.framework/Frameworks');member.type=tarfile.SYMTYPE;member.linkname='Versions/Current/Frameworks'
            members={member.name:member}
            hosted.verify_complete_links(root,members)
            for target in ['Versions/A/Missing','/tmp','../../outside']:
                (root/member.name).unlink();(root/member.name).symlink_to(target);member.linkname=target
                with self.assertRaises(ValueError):hosted.verify_complete_links(root,members)


class NativeDriverChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        native_spec=importlib.util.spec_from_file_location('native_driver',Path(__file__).with_name('run-native.py'))
        cls.native=importlib.util.module_from_spec(native_spec);native_spec.loader.exec_module(cls.native)

    def test_native_environment_reconstructs_frameworks_without_ci_credentials(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);(root/'runtime').mkdir()
            with patch.dict('os.environ',{'GH_TOKEN':'owned-test-token','GITHUB_TOKEN':'owned-test-token','ACTIONS_RUNTIME_TOKEN':'owned-test-token','DYLD_FRAMEWORK_PATH':'/wrong','__XPC_DYLD_FRAMEWORK_PATH':'/wrong'}):
                environment=self.native.child_environment(root)
            self.assertEqual(environment['DYLD_FRAMEWORK_PATH'],str((root/'runtime').resolve()))
            self.assertEqual(environment['__XPC_DYLD_FRAMEWORK_PATH'],str((root/'runtime').resolve()))
            self.assertFalse(any('TOKEN' in key for key in environment))

    def test_bounded_owned_child_timeout_preserves_log(self):
        import sys
        with tempfile.TemporaryDirectory() as raw:
            log=Path(raw)/'timeout.log'
            with self.assertRaises(TimeoutError):
                self.native.bounded([sys.executable,'-c','import time;print("OWNED_CHILD_STARTED",flush=True);time.sleep(10)'],log,{},1.0)
            self.assertIn('OWNED_CHILD_STARTED',log.read_text())

    def test_cleanup_refuses_success_when_ownership_journal_remains(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);(root/'harness').mkdir();(root/'evidence').mkdir()
            (root/'harness/probe').touch();journal=root/'harness/probe.owned-stores.json';journal.write_text('[]')
            with patch.object(self.native,'verify_prepared'),patch.object(self.native,'child_environment',return_value={}),patch.object(self.native,'bounded',return_value=0):
                self.assertFalse(self.native.cleanup(root))
                journal.unlink()
                self.assertTrue(self.native.cleanup(root))

    def test_source_gates_cannot_be_skipped_even_on_successful_job(self):
        steps=[{'name':name,'status':'completed','conclusion':'success'} for name in ('Verify 26 microtask entry and realm controls','Verify the extension APIs in the built framework','Upload the compiled native runtime')]
        jobs={'total_count':1,'jobs':[{'name':'macos','status':'completed','conclusion':'success','steps':steps}]}
        hosted.verify_jobs(jobs)
        steps[0]['conclusion']='skipped'
        with self.assertRaises(ValueError):hosted.verify_jobs(jobs)

    def test_recovery_exception_revokes_qualification_receipt(self):
        from unittest.mock import patch
        import sys
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);(root/'evidence').mkdir()
            receipt=root/'evidence/qualification.json'
            receipt.write_text(json.dumps({'qualified':True,'fullOriginalUBlockQualified':True,'cleanupSucceeded':True}))
            with patch.object(sys,'argv',['run-native.py','cleanup','--work-root',str(root)]),patch.object(self.native,'cleanup',side_effect=ValueError('changed receipt')),patch.object(self.native.signal,'signal'):
                self.assertEqual(self.native.main(),1)
            result=json.loads(receipt.read_text())
            self.assertFalse(result['qualified'])
            self.assertFalse(result['fullOriginalUBlockQualified'])
            self.assertFalse(result['cleanupSucceeded'])

if __name__=='__main__': unittest.main()
