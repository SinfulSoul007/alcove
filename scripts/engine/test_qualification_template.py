"""Unexecuted qualification-app composition with the actual frozen vendor data."""
import copy
import hashlib
import importlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_engine_packaging import relocation_fixture

HERE = Path(__file__).resolve().parent
ASSET_ROOT = os.environ.get('ALCOVE_QUALIFICATION_ASSETS')


class QualificationInputChecks(unittest.TestCase):
    def setUp(self):
        try: self.module = importlib.import_module('qualification')
        except ModuleNotFoundError: self.fail('The qualification template implementation is missing')
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.witness = HERE/'FullUBlockQualificationChecks.swift'

    def test_changed_witness_is_rejected(self):
        bad = self.root/'changed.swift'; bad.write_bytes(b'changed qualification test')
        with self.assertRaisesRegex(ValueError, 'witness'):
            self.module.verify_qualification_inputs(bad, {})

    def test_partial_source_context_is_rejected_before_input_io(self):
        for context in ({}, {'package':self.root/'source'},
                        {'package':self.root/'source','repository':self.root/'git','contract':self.root/'contract','extra':self.root}):
            with self.subTest(context=context):
                with self.assertRaisesRegex(ValueError,'source|Source'):
                    self.module.assemble_unsigned_template(self.root/'missing-engine', {}, self.root/'missing-runtime',
                        self.root/'missing-main','0'*64,self.witness,{},self.root/'out.app',source_inputs=context)
                self.assertFalse((self.root/'out.app').exists())

    def test_source_verification_context_is_required_when_rechecking_source_template(self):
        with self.assertRaisesRegex(ValueError,'source|Source'):
            self.module.verify_unsigned_template(self.root/'missing-app',{}, {},self.root/'missing-runtime',
                self.root/'missing-main',self.witness,{},source_inputs={'package':self.root/'source'})

    def test_template_destination_cannot_mutate_source_material(self):
        engine = self.root/'engine';engine.mkdir()
        runtime = self.root/'runtime';runtime.mkdir()
        source = self.root/'source';source.mkdir()
        context = {'package':source,'repository':self.root/'git','contract':self.root/'contract'}
        out = source/'nested.app'
        with self.assertRaisesRegex(ValueError,'destination|input tree'):
            self.module.assemble_unsigned_template(engine,{},runtime,self.root/'missing-main',
                '0'*64,self.witness,{},out,source_inputs=context)
        self.assertFalse(out.exists())

    def test_missing_archive_variant_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'archive|asset'):
            self.module.verify_qualification_inputs(self.witness, {})

    def test_changed_vendor_archive_is_rejected(self):
        assets = {}
        for kind in ('zip', 'crx'):
            assets[kind] = self.root/kind; assets[kind].write_bytes(b'changed original archive')
        with self.assertRaisesRegex(ValueError, 'archive|asset'):
            self.module.verify_qualification_inputs(self.witness, assets)

    def test_symbolic_witness_is_rejected(self):
        link = self.root/'linked.swift'; link.symlink_to(self.witness)
        with self.assertRaisesRegex(ValueError, 'witness|regular'):
            self.module.verify_qualification_inputs(link, {})

    def test_existing_app_is_preserved_before_other_inputs_are_read(self):
        app = self.root/'keep.app'; app.mkdir(); (app/'keep.txt').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'destination'):
            self.module.assemble_unsigned_template(self.root/'absent', {}, self.root/'absent-runtime',
                self.root/'absent-main', '0'*64, self.witness, {}, app)
        self.assertEqual((app/'keep.txt').read_bytes(), b'keep')

    def test_compiler_preserves_existing_build_output(self):
        output = self.root/'existing'; output.mkdir(); (output/'keep').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'destination|output'):
            self.module.compile_qualification_entry(self.root/'missing-source', output, self.root/'missing-sdk')
        self.assertEqual((output/'keep').read_bytes(), b'keep')

    def test_compiler_rejects_unknown_app_source_without_output(self):
        output = self.root/'new-build'
        with self.assertRaisesRegex(ValueError, 'source|baseline'):
            self.module.compile_qualification_entry(self.root/'missing-source', output, self.root/'missing-sdk')
        self.assertFalse(output.exists())

    def test_compiler_rejects_unavailable_sdk_without_output(self):
        output = self.root/'new-build'
        with self.assertRaisesRegex(ValueError, 'SDK|sdk'):
            self.module.compile_qualification_entry(HERE.parent.parent, output, self.root/'missing-sdk')
        self.assertFalse(output.exists())

    def command(self, manifest):
        engine = self.root/'engine-input'; engine.mkdir(exist_ok=True)
        runtime = self.root/'runtime-input'; runtime.mkdir(exist_ok=True)
        receipt = self.root/'engine.json'; receipt.write_text('{}')
        return [sys.executable, str(HERE/'qualification.py'), 'prepare-template',
            '--repository', str(HERE.parent.parent), '--engine-tree', str(engine),
            '--engine-receipt', str(receipt), '--runtime', str(runtime),
            '--assets', str(self.root/'missing-assets'), '--build', str(self.root/'build'),
            '--app', str(self.root/'app.app'), '--manifest', str(manifest)]

    def test_cli_rejects_partial_source_flags_before_compilation(self):
        result = subprocess.run(self.command(self.root/'manifest.json')+['--source-package',str(self.root/'source')],
            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
        self.assertEqual(result.returncode,1)
        self.assertIn('source',json.loads(result.stdout)['error'].lower())
        self.assertFalse((self.root/'build').exists())
        self.assertFalse((self.root/'app.app').exists())

    def test_cli_preserves_existing_manifest_and_publishes_nothing(self):
        manifest = self.root/'keep.json'; manifest.write_bytes(b'keep manifest')
        result = subprocess.run(self.command(manifest), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(manifest.read_bytes(), b'keep manifest')
        self.assertFalse((self.root/'build').exists())
        self.assertFalse((self.root/'app.app').exists())

    def test_cli_rejects_manifest_inside_app_and_bad_assets_without_output(self):
        for manifest in (self.root/'app.app/manifest.json', self.root/'outside.json'):
            with self.subTest(manifest=manifest):
                result = subprocess.run(self.command(manifest), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root/'build').exists())
                self.assertFalse((self.root/'app.app').exists())
                self.assertFalse(manifest.exists())


@unittest.skipUnless(ASSET_ROOT and shutil.which('install_name_tool'), 'Set ALCOVE_QUALIFICATION_ASSETS to pinned ZIP/CRX inputs on macOS')
class QualificationAssemblyChecks(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module('qualification')
        self.package = importlib.import_module('package_candidate')
        self.metadata = importlib.import_module('macho_metadata')
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.runtime = self.root/'runtime'; self.runtime.mkdir()
        self.web = 'WebKit.framework/Versions/A/WebKit'
        path = self.runtime/self.web; path.parent.mkdir(parents=True)
        path.write_bytes(relocation_fixture('/System/Library/Frameworks/'+self.web, rpath='/developer/runtime'))
        path.chmod(0o755)
        self.engine = self.root/'engine'
        self.receipt = self.package.prepare_relocated_runtime_layout(self.runtime, self.engine)
        self.main = self.root/'original-main'
        self.main.write_bytes(relocation_fixture(None, dependency='/System/Library/Frameworks/'+self.web, rpath='/developer/runtime'))
        self.main.chmod(0o755)
        self.main_sha = hashlib.sha256(self.main.read_bytes()).hexdigest()
        self.witness = HERE/'FullUBlockQualificationChecks.swift'
        self.assets = {kind:Path(ASSET_ROOT)/('uBlock0_1.76.4.chromium.'+kind) for kind in ('zip','crx')}
        self.app = self.root/'Qualification.app'

    def assemble(self):
        return self.module.assemble_unsigned_template(self.engine, self.receipt, self.runtime,
            self.main, self.main_sha, self.witness, self.assets, self.app)

    def verify(self, manifest):
        return self.module.verify_unsigned_template(self.app, manifest, self.receipt, self.runtime,
            self.main, self.witness, self.assets)

    def test_real_assets_and_engine_compose_without_native_qualification(self):
        original = self.main.read_bytes(); manifest = self.assemble()
        proof = self.verify(manifest)
        self.assertTrue(proof['staticTemplateVerified'])
        self.assertFalse(proof['nativeAppQualified'])
        self.assertTrue(proof['signingPending'])
        self.assertEqual(self.main.read_bytes(), original)
        info = plistlib.loads((self.app/'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.openbrowser.mac.engine-qualification')
        self.assertEqual(info['LSMinimumSystemVersion'], '26.5')
        image = self.metadata.inspect_image((self.app/'Contents/MacOS/AlcoveEngineQualification').read_bytes())
        self.assertEqual(image['dependencies'], ['@rpath/WebKit.framework/Versions/A/WebKit'])
        for kind in ('zip','crx'):
            self.assertEqual((self.app/'Contents/Resources/Qualification'/self.assets[kind].name).read_bytes(), self.assets[kind].read_bytes())

    def test_complete_template_verifies_after_moving(self):
        manifest = self.assemble(); moved = self.root/'Moved.app'; self.app.rename(moved); self.app = moved
        self.verify(manifest)

    def test_output_inside_an_input_tree_is_rejected_before_recursive_copy(self):
        for parent in (self.engine, self.runtime):
            with self.subTest(parent=parent):
                self.app = parent/'Nested.app'
                # Prevent the known recursive filesystem side effect while
                # exercising the real preflight and its expected rejection.
                with patch('qualification.shutil.copytree', side_effect=AssertionError('reached forbidden recursive copy')):
                    with self.assertRaisesRegex(ValueError, 'destination|input tree'):
                        self.assemble()
                self.assertFalse(self.app.exists())
                self.package.verify_relocated_runtime_layout(self.engine, self.receipt, self.runtime)

    def test_missing_vendor_input_and_unlisted_code_are_rejected(self):
        manifest = self.assemble()
        archive = self.app/'Contents/Resources/Qualification'/self.assets['zip'].name
        archive.unlink()
        with self.assertRaisesRegex(ValueError, 'missing|type|archive'):
            self.verify(manifest)
        shutil.copyfile(self.assets['zip'], archive); archive.chmod(0o644)
        (self.app/'Contents/MacOS/unlisted').write_bytes(b'unlisted executable')
        with self.assertRaisesRegex(ValueError, 'Unexpected|member'):
            self.verify(manifest)

    def test_self_reported_hash_cannot_relabel_minimum_os(self):
        manifest = self.assemble(); path = self.app/'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes()); info['LSMinimumSystemVersion'] = '14.0'
        path.write_bytes(plistlib.dumps(info))
        altered = copy.deepcopy(manifest)
        for item in altered['additionalFiles']:
            if item['destination'] == 'Contents/Info.plist': item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'metadata|template|provenance'):
            self.verify(altered)

    def test_wrong_entry_architecture_publishes_no_app(self):
        data = bytearray(self.main.read_bytes()); struct.pack_into('<I', data, 4, 0x01000007)
        self.main.write_bytes(data); self.main_sha = hashlib.sha256(data).hexdigest()
        with self.assertRaisesRegex(ValueError, 'arm64|architecture'):
            self.assemble()
        self.assertFalse(self.app.exists())

    def test_newer_sdk_label_is_preserved_with_the_required_deployment_floor(self):
        data = bytearray(self.main.read_bytes()); struct.pack_into('<I', data, 32+232+16, 0x001B0000)
        self.main.write_bytes(data); self.main_sha = hashlib.sha256(data).hexdigest()
        manifest = self.assemble(); self.verify(manifest)
        info = self.metadata.inspect_image((self.app/'Contents/MacOS/AlcoveEngineQualification').read_bytes())
        self.assertEqual(info['platform'], {'platform':1, 'minimum':0x001A0500, 'sdk':0x001B0000})

    def test_wrong_deployment_floor_or_older_sdk_publishes_no_app(self):
        original = self.main.read_bytes()
        for offset,value in ((32+232+12,0x001A0600),(32+232+16,0x001A0000)):
            with self.subTest(offset=offset):
                data = bytearray(original); struct.pack_into('<I',data,offset,value)
                self.main.write_bytes(data); self.main_sha = hashlib.sha256(data).hexdigest()
                with self.assertRaisesRegex(ValueError, 'platform|minimum|SDK'):
                    self.assemble()
                self.assertFalse(self.app.exists())


if __name__ == '__main__': unittest.main()
