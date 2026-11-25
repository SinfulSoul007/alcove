"""Real binary fixtures exercise packaging boundaries, without loading code."""
import hashlib
import importlib
import copy
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path


def command(kind, payload):
    size = (8 + len(payload) + 7) & ~7
    return struct.pack('<II', kind, size) + payload + bytes(size - 8 - len(payload))


def fixture(environment=('DYLD_FRAMEWORK_PATH=@executable_path/../../..',
                         'DYLD_LIBRARY_PATH=@executable_path/../../..')):
    # Hand-built 64-bit arm64 dylib: text/data live at fixed file offsets.
    sections = b''
    for name, offset, size in ((b'__text', 4096, 16), (b'__const', 4112, 16)):
        sections += struct.pack('<16s16sQQIIIIIIII', name, b'__TEXT',
                                0x100000000 + offset, size, offset, 2, 0, 0, 0, 0, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, 72 + len(sections), b'__TEXT',
                          0x100000000, 8192, 0, 4128, 5, 5, 2, 0) + sections
    build = command(0x32, struct.pack('<IIII', 1, 0x001A0500, 0x001A0500, 0))
    identity = command(0xD, struct.pack('<IIII', 24, 0, 0x10000, 0x10000) +
                       b'/System/Library/Frameworks/Owned.framework/Owned\0')
    commands = [segment, build, identity]
    commands += [command(0x27, struct.pack('<I', 12) + item.encode() + b'\0') for item in environment]
    table = b''.join(commands)
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 6, len(commands), len(table), 0, 0)
    return header + table + bytes(4096 - len(header) - len(table)) + b'OWNED_TEXT_BYTES' + b'OWNED_DATA_BYTES'


class MachOPackagingChecks(unittest.TestCase):
    def setUp(self):
        try:
            self.metadata = importlib.import_module('macho_metadata')
        except ModuleNotFoundError:
            self.fail('The engine packaging metadata implementation is missing')

    def test_removes_duplicate_developer_commands_without_changing_sections(self):
        before = fixture(('DYLD_FRAMEWORK_PATH=@loader_path',) * 2)
        after = self.metadata.remove_developer_environment(before)
        info = self.metadata.inspect_image(after)
        self.assertEqual(info['environment'], [])
        self.assertEqual(struct.unpack_from('<I', after, 16)[0], 3)
        self.assertEqual(after[4096:], b'OWNED_TEXT_BYTESOWNED_DATA_BYTES')
        self.assertEqual([s['offset'] for s in info['sections']], [4096, 4112])
        self.assertEqual([s['sha256'] for s in info['sections']], [
            hashlib.sha256(b'OWNED_TEXT_BYTES').hexdigest(),
            hashlib.sha256(b'OWNED_DATA_BYTES').hexdigest()])
        self.metadata.verify_derivation(before, after, {'removeDeveloperEnvironment': True})

    def test_image_without_developer_commands_is_byte_identical(self):
        before = fixture(())
        self.assertEqual(self.metadata.remove_developer_environment(before), before)

    def test_refuses_short_unaligned_or_overflowing_load_commands(self):
        for size in (0, 4, 7, 9, 0xFFFFFFF8):
            with self.subTest(size=size):
                raw = bytearray(fixture()); struct.pack_into('<I', raw, 36, size)
                with self.assertRaisesRegex(ValueError, 'load command'):
                    self.metadata.inspect_image(bytes(raw))

    def test_refuses_command_count_or_table_size_disagreement(self):
        for offset, value in ((16, 0xFFFFFFFF), (20, 0xFFFFFFF8), (16, 1)):
            with self.subTest(offset=offset, value=value):
                raw = bytearray(fixture()); struct.pack_into('<I', raw, offset, value)
                with self.assertRaisesRegex(ValueError, 'load command'):
                    self.metadata.inspect_image(bytes(raw))

    def test_refuses_environment_string_without_terminator(self):
        raw = bytearray(fixture(('DYLD_FRAMEWORK_PATH=x',)))
        index = bytes(raw).index(b'DYLD_FRAMEWORK_PATH=x')
        table_end = 32 + struct.unpack_from('<I', raw, 20)[0]
        raw[index:table_end] = b'x' * (table_end-index)
        with self.assertRaisesRegex(ValueError, 'string'):
            self.metadata.inspect_image(bytes(raw))

    def test_refuses_environment_string_offset_inside_command_header(self):
        raw = bytearray(fixture(('DYLD_FRAMEWORK_PATH=x',)))
        index = bytes(raw).index(b'DYLD_FRAMEWORK_PATH=x')
        struct.pack_into('<I', raw, index-4, 8)
        with self.assertRaisesRegex(ValueError, 'string offset'):
            self.metadata.inspect_image(bytes(raw))

    def test_refuses_unapproved_environment_key(self):
        with self.assertRaisesRegex(ValueError, 'environment'):
            self.metadata.remove_developer_environment(fixture(('DYLD_UNREVIEWED_KEY=value',)))

    def test_refuses_section_overlapping_load_table(self):
        raw = bytearray(fixture()); struct.pack_into('<I', raw, 32 + 72 + 48, 64)
        with self.assertRaisesRegex(ValueError, 'section'):
            self.metadata.inspect_image(bytes(raw))

    def test_refuses_section_beyond_image(self):
        raw = bytearray(fixture()); struct.pack_into('<Q', raw, 32 + 72 + 40, 999999)
        with self.assertRaisesRegex(ValueError, 'section'):
            self.metadata.inspect_image(bytes(raw))

    def test_refuses_fat_or_foreign_cpu_images(self):
        for offset, value in ((0, 0xCAFEBABE), (4, 0x01000007)):
            with self.subTest(offset=offset):
                raw = bytearray(fixture()); struct.pack_into('<I', raw, offset, value)
                with self.assertRaisesRegex(ValueError, 'arm64'):
                    self.metadata.inspect_image(bytes(raw))

    def test_derivation_rejects_code_or_data_change(self):
        before = fixture()
        for offset in (4096, 4112):
            with self.subTest(offset=offset):
                after = bytearray(self.metadata.remove_developer_environment(before)); after[offset] ^= 1
                with self.assertRaisesRegex(ValueError, 'section|content'):
                    self.metadata.verify_derivation(before, bytes(after), {'removeDeveloperEnvironment': True})

    def test_derivation_rejects_platform_floor_change(self):
        before = fixture(); after = bytearray(self.metadata.remove_developer_environment(before))
        # Segment command is 232 bytes. Build-version minos follows cmd/size/platform.
        struct.pack_into('<I', after, 32 + 232 + 12, 0x000E0000)
        with self.assertRaisesRegex(ValueError, 'load command|platform'):
            self.metadata.verify_derivation(before, bytes(after), {'removeDeveloperEnvironment': True})


class EngineInputChecks(unittest.TestCase):
    def setUp(self):
        try:
            self.inputs = importlib.import_module('verified_input')
        except ModuleNotFoundError:
            self.fail('The verified engine input implementation is missing')

    def test_rejects_foreign_source_checkout(self):
        with self.assertRaisesRegex(ValueError, 'source revision'):
            self.inputs.verify_source_contract(Path(__file__).resolve().parents[2])

    def test_rejects_changed_archive_before_creating_destination(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);archive=root/'changed.zip';archive.write_bytes(b'changed engine archive')
            destination=root/'runtime'
            with self.assertRaisesRegex(ValueError, 'archive'):
                self.inputs.verify_and_extract(archive, root/'contract', destination)
            self.assertFalse(destination.exists())

    def test_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);destination=root/'runtime';destination.mkdir();(destination/'owned.txt').write_text('keep')
            with self.assertRaisesRegex(ValueError, 'destination'):
                self.inputs.verify_and_extract(root/'missing.zip', root/'contract', destination)
            self.assertEqual((destination/'owned.txt').read_text(), 'keep')

    def test_complete_link_gate_accepts_only_the_pinned_optional_framework_link(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);(root/'WebCore.framework/Versions/A').mkdir(parents=True)
            (root/'WebCore.framework/Versions/Current').symlink_to('A')
            link=root/'WebCore.framework/Frameworks';link.symlink_to('Versions/Current/Frameworks')
            member=tarfile.TarInfo('WebCore.framework/Frameworks');member.type=tarfile.SYMTYPE;member.linkname='Versions/Current/Frameworks'
            self.inputs.verify_complete_links(root,{member.name:member})
            for target in ('Versions/A/OtherMissing','/tmp','../../outside'):
                with self.subTest(target=target):
                    link.unlink();link.symlink_to(target);member.linkname=target
                    with self.assertRaisesRegex(ValueError, 'link'):
                        self.inputs.verify_complete_links(root,{member.name:member})

    def test_rejects_source_or_freshness_manifest_change(self):
        patches={'owned.patch':'1'*64}
        value={'formatVersion':1,'source':{'formatVersion':1,
            'wrapperCommit':'1fc08bd2013efe318f3d7b7914a24dcf9af07916',
            'webkitRevision':'26695efdefc6076049ec50713a2c4e54b90b4d47','patches':patches,
            'emptyProductsAtStart':True,'sdk':'26.5',
            'appliedSourceSHA256':'206841ff15632f71f2972f8f530500b00de48b1b4adc71c35a6c5a8d799d6be8',
            'buildCommand':['Tools/Scripts/build-webkit','--release','--only=Everything up to WebKit',
                            'GCC_GENERATE_DEBUGGING_SYMBOLS=NO','COMPILER_INDEX_STORE_ENABLE=NO']},
            'frameworkSHA256':{
                'JavaScriptCore.framework':'df403fd0b9399f611302aa11df3db3730972a7e15736935f1535cb69cca21877',
                'WebCore.framework':'7c35f3c07bac9c58a9e13403c6750f434e1c2cf66212ed5b07df4b249834b3f2',
                'WebKit.framework':'ac499ef069ae0a138f2b099fb84d84be0cc7072fa06a1a929afca3758fd86ba2'}}
        self.inputs.verify_build_manifest(value, patches)
        for field,replacement in (('formatVersion',2),('wrapperCommit','0'*40),('webkitRevision','0'*40),
                                  ('patches',{}),('emptyProductsAtStart',False),('sdk','26.4'),
                                  ('appliedSourceSHA256','0'*64),('buildCommand',[])):
            with self.subTest(field=field):
                candidate=copy.deepcopy(value);candidate['source'][field]=replacement
                with self.assertRaisesRegex(ValueError, 'manifest'):
                    self.inputs.verify_build_manifest(candidate, patches)
        candidate=copy.deepcopy(value);candidate['frameworkSHA256']['WebCore.framework']='0'*64
        with self.assertRaisesRegex(ValueError, 'manifest'):
            self.inputs.verify_build_manifest(candidate, patches)


if __name__ == '__main__':
    unittest.main()
