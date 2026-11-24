#!/usr/bin/env python3
"""Execute real workflow metadata code and pinned make argument forwarding."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT=Path(__file__).resolve().parents[1]
WORKFLOW=ROOT/'.github/workflows/build-jsc-realms.yml'
class WorkflowChecks(unittest.TestCase):
    def test_actual_metadata_code_rejects_another_upstream_revision(self):
        text=WORKFLOW.read_text()
        code=re.search(r'python3 - "\$metadata" <<\'PY\'\n(.*?)\n          PY',text,re.S).group(1)
        code=textwrap.dedent(code)
        contract=json.loads((ROOT/'diagnostics/jsc-runtime-baseline.json').read_text())
        with tempfile.TemporaryDirectory(prefix='alcove-workflow-metadata-') as raw:
            root=Path(raw);(root/'diagnostics').mkdir()
            (root/'diagnostics/jsc-runtime-baseline.json').write_text(json.dumps(contract))
            metadata=root/'metadata.json';metadata.write_text(json.dumps({'id':contract['artifactID'],'expired':False,'digest':'sha256:'+contract['archiveSHA256']}))
            env=dict(os.environ,WEBKIT_REVISION=contract['webkitRevision'])
            result=subprocess.run([sys.executable,'-',str(metadata)],input=code,cwd=root,env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            env['WEBKIT_REVISION']='0'*40
            result=subprocess.run([sys.executable,'-',str(metadata)],input=code,cwd=root,env=env,text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0,'Metadata code accepted a different source pin')
    def test_actual_build_arguments_reach_xcodebuild(self):
        commands=re.findall(r'^\s*Tools/Scripts/build-jsc --release[^\n]+',WORKFLOW.read_text(),re.M)
        self.assertTrue(commands)
        for command in commands:
            arguments=shlex.split(command.strip().split(' 2>&1')[0])[2:]
            with tempfile.TemporaryDirectory(prefix='alcove-upstream-make-') as raw:
                result=subprocess.run(['make','--no-print-directory','-n','-f',str(ROOT/'diagnostics/fixtures/WebKit-Makefile.shared'),'release',*arguments],cwd=raw,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
                invocation=next(line for line in result.stdout.splitlines() if 'xcodebuild ' in line)
                self.assertIn('GCC_GENERATE_DEBUGGING_SYMBOLS=NO',invocation)
                self.assertIn('COMPILER_INDEX_STORE_ENABLE=NO',invocation)
if __name__=='__main__':unittest.main()
