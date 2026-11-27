"""Prepare an unsealed qualification app; never launch or qualify it here."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from bundle_layout import is_owned_reference, plan_relocations
from image_relocation import relocate_image_copy, verify_relocation
from macho_metadata import inspect_image
from package_candidate import runtime_images, verify_relocated_runtime_layout
from source_notices import source_readme_bytes, verify_engine_source_package
from verified_input import require

HERE = Path(__file__).resolve().parent
WITNESS_SHA = '2155d8b27904ca8105f3debee0d3f30242fa387c13d39d0072ed3fcdfea7b725'
ASSETS = {
    'zip': (6149497, '4b1b27ed82e734d508ae6d255933c334f62f256e8a8aece92724b826828e3d5f'),
    'crx': (6054573, 'ee44e69bb7a0e162bf08632929a5059bd676dfaa3ae2267e3c4eb11cc949b21a'),
}
IDENTIFIER = 'dev.openbrowser.mac.engine-qualification'
EXECUTABLE = 'Contents/MacOS/AlcoveEngineQualification'
APP_BASE = 'efeedfd8bf7e64284762bbcaa3bc8ed4a6134ea9'
APP_ENTITLEMENTS = {name:True for name in (
    'com.apple.security.app-sandbox', 'com.apple.security.network.client',
    'com.apple.security.files.user-selected.read-write', 'com.apple.security.print',
    'com.apple.security.device.camera', 'com.apple.security.device.audio-input')}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_qualification_inputs(witness, assets):
    witness = Path(witness)
    require(witness.is_file() and not witness.is_symlink() and sha(witness.read_bytes()) == WITNESS_SHA,
            'Frozen qualification witness changed or is not a regular file')
    require(set(assets) == set(ASSETS), 'Both original vendor archive assets are required')
    for kind, (size, digest) in ASSETS.items():
        path = Path(assets[kind])
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == size and
                sha(path.read_bytes()) == digest, 'Original vendor archive asset changed: '+kind)
    return {'witnessSHA256':WITNESS_SHA,
            'assets':{kind:{'bytes':size, 'sha256':digest} for kind,(size,digest) in ASSETS.items()}}


def info_bytes():
    return plistlib.dumps({'CFBundleIdentifier':IDENTIFIER, 'CFBundleExecutable':'AlcoveEngineQualification',
        'CFBundleName':'Alcove Engine Qualification', 'CFBundlePackageType':'APPL',
        'CFBundleShortVersionString':'0.0.0', 'CFBundleVersion':'1', 'NSPrincipalClass':'NSApplication',
        'NSHighResolutionCapable':True, 'LSMinimumSystemVersion':'26.5', 'LSRequiresNativeExecution':True})


def template_data(witness, assets):
    files = {'Contents/Info.plist':info_bytes(),
             'Contents/Resources/Qualification/FullUBlockQualificationChecks.swift':Path(witness).read_bytes()}
    for kind in ASSETS:
        files['Contents/Resources/Qualification/uBlock0_1.76.4.chromium.'+kind] = Path(assets[kind]).read_bytes()
    return files


def verify_entry_platform(info):
    require(info['header'][3] == 2 and info['identity'] is None, 'Qualification entry must be an executable')
    platform = info['platform']
    require(platform['platform'] == 1 and platform['minimum'] == 0x001A0500 and platform['sdk'] >= platform['minimum'],
            'Qualification entry needs the macOS26.5 deployment floor and a compatible SDK: '+str(platform))


def entry_plan(original, runtime, receipt):
    info = inspect_image(original)
    verify_entry_platform(info)
    images = runtime_images(runtime, receipt['inputLayout']['members'])
    plans = plan_relocations(images)
    identities = {image['identity']:plans[image['path']]['identity']
                  for image in images if image['identity'] is not None}
    changes = {}
    for dependency in info['dependencies']:
        if dependency in identities:
            if identities[dependency] != dependency: changes[dependency] = identities[dependency]
        else:
            require(dependency.startswith(('/System/Library/', '/usr/lib/')) and not is_owned_reference(dependency),
                    'Unmapped qualification entry dependency')
    return {'identity':None, 'changes':changes, 'removeRpaths':info['rpaths'],
            'addRpath':'@loader_path/../Frameworks'}


def descriptor(name, data, mode):
    return {'destination':name, 'kind':'file', 'sha256':sha(data), 'mode':mode}


def source_context(inputs):
    if inputs is None: return None
    require(isinstance(inputs, dict) and set(inputs) == {'package','repository','contract'} and
            all(isinstance(path, Path) for path in inputs.values()), 'Complete source package/Git/contract inputs are required')
    return inputs


def source_template_data(inputs, runtime):
    inputs = source_context(inputs)
    if inputs is None: return {}, None
    package = inputs['package']
    receipt = verify_engine_source_package(package,inputs['repository'],inputs['contract'],runtime)
    material = {'source':receipt, 'correspondingSource':{
        'kind':'companion-source-package', 'archive':'WebKit-source.tar.gz',
        'archiveSHA256':receipt['archiveSHA256'], 'published':False}}
    files = {'Contents/Resources/EngineSource/SourceMaterial.json':(json.dumps(material,indent=2)+'\n').encode(),
             'Contents/Resources/EngineSource/README.txt':source_readme_bytes()}
    for notice in receipt['notices']:
        data = (package/'upstream/notices'/notice['path']).read_bytes()
        require(len(data) == notice['bytes'] and sha(data) == notice['sha256'], 'Source notice changed before template copy')
        files['Contents/Resources/EngineSource/notices/'+notice['path']] = data
    return files, receipt


def verify_unsigned_template(app, manifest, engine_receipt, runtime, original_main, witness, assets, *, source_inputs=None):
    source_context(source_inputs)
    app, runtime = Path(app), Path(runtime)
    inputs = verify_qualification_inputs(witness, assets)
    require(manifest['formatVersion'] == 1 and manifest['nativeAppQualified'] is False and
            manifest['ordinaryAppQualified'] is False and manifest['signingPending'] is True and
            manifest['sandboxQualified'] is False, 'Invalid unqualified template receipt')
    require(manifest['frozenInputs'] == inputs and manifest['requiredAppEntitlements'] == APP_ENTITLEMENTS,
            'Qualification template provenance or signing intent changed')
    source_files, source_receipt = source_template_data(source_inputs,runtime)
    require(manifest.get('sourceMaterial') == source_receipt, 'Qualification source material changed or its context is missing')
    original = Path(original_main).read_bytes()
    plan = entry_plan(original, runtime, engine_receipt)
    require(manifest['entryPlan'] == plan and manifest['originalEntrySHA256'] == sha(original),
            'Qualification entry source/plan receipt changed')
    files = dict(template_data(witness, assets), **source_files)
    expected = [descriptor(name, data, 0o644) for name,data in sorted(files.items())]
    after = (app/EXECUTABLE).read_bytes()
    proof = verify_relocation(original, after, plan)
    require(manifest['entryProof'] == proof, 'Qualification entry derivation receipt changed')
    expected.append(descriptor(EXECUTABLE, after, 0o755))
    require(manifest['additionalFiles'] == expected, 'Qualification template metadata/provenance changed')
    require((app/'Contents/Info.plist').read_bytes() == info_bytes(), 'Qualification template metadata changed')
    verify_relocated_runtime_layout(app, engine_receipt, runtime, additional_files=expected)
    return {'staticTemplateVerified':True, 'engineImages':len(engine_receipt['images']),
            'frozenWitnessSHA256':WITNESS_SHA, 'nativeAppQualified':False,
            'ordinaryAppQualified':False, 'sandboxQualified':False, 'signingPending':True,
            'sourceNoticesIntegrated':source_inputs is not None,
            'sourceCompanionArchiveSHA256':source_receipt['archiveSHA256'] if source_receipt else None}


def assemble_unsigned_template(engine_tree, engine_receipt, runtime, original_main, expected_main_sha,
                               witness, assets, destination, *, source_inputs=None):
    source_context(source_inputs)
    destination, runtime = Path(destination), Path(runtime)
    require(not destination.exists() and not destination.is_symlink(), 'Qualification destination already exists')
    resolved = destination.resolve(strict=False)
    require(not resolved.is_relative_to(Path(engine_tree).resolve(strict=True)) and
            not resolved.is_relative_to(runtime.resolve(strict=True)),
            'Qualification destination is inside an immutable input tree')
    if source_inputs is not None:
        require(all(not resolved.is_relative_to(path.resolve(strict=False)) for path in source_inputs.values()),
                'Qualification destination is inside a source input tree')
    inputs = verify_qualification_inputs(witness, assets)
    original = Path(original_main).read_bytes()
    require(sha(original) == expected_main_sha, 'Qualification entry input digest changed')
    plan = entry_plan(original, runtime, engine_receipt)
    verify_relocated_runtime_layout(Path(engine_tree), engine_receipt, runtime)
    source_files, source_receipt = source_template_data(source_inputs,runtime)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-qualification-template-', dir=destination.parent) as raw:
        stage = Path(raw)/'Qualification.app'
        shutil.copytree(engine_tree, stage, symlinks=True)
        additional = []
        for name, data in sorted(dict(template_data(witness, assets), **source_files).items()):
            path = stage/name
            require(not path.exists() and not path.is_symlink(), 'Template file overlaps engine member')
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data); path.chmod(0o644)
            additional.append(descriptor(name, data, 0o644))
        proof = relocate_image_copy(Path(original_main), stage/EXECUTABLE, plan, expected_main_sha)
        additional.append(descriptor(EXECUTABLE, (stage/EXECUTABLE).read_bytes(), 0o755))
        manifest = {'formatVersion':1, 'frozenInputs':inputs, 'originalEntrySHA256':expected_main_sha,
                    'entryPlan':plan, 'entryProof':proof, 'additionalFiles':additional,
                    'requiredAppEntitlements':APP_ENTITLEMENTS.copy(),
                    'sourceMaterial':source_receipt,
                    'nativeAppQualified':False, 'ordinaryAppQualified':False,
                    'sandboxQualified':False, 'signingPending':True}
        manifest['verification'] = verify_unsigned_template(stage, manifest, engine_receipt, runtime,
            original_main, witness, assets, source_inputs=source_inputs)
        require(not destination.exists() and not destination.is_symlink(), 'Qualification destination appeared during staging')
        stage.rename(destination)
    return manifest


def source_snapshot(repository):
    process = subprocess.run(['git', '-C', str(repository), 'ls-tree', '-r', '-z', APP_BASE, '--', 'Sources'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    require(process.returncode == 0 and process.stdout, 'Frozen app source baseline is unavailable')
    expected = {}
    for row in process.stdout.split(b'\0'):
        if not row: continue
        metadata, name = row.split(b'\t', 1)
        mode, kind, blob = metadata.split()
        require(mode in (b'100644', b'100755') and kind == b'blob', 'Unexpected frozen source member')
        expected[name.decode('utf-8')] = blob.decode('ascii')
    actual = {path.relative_to(repository).as_posix() for path in (repository/'Sources').rglob('*')
              if path.is_file() or path.is_symlink()}
    require(actual == set(expected), 'Frozen app source inventory changed')
    result = {}
    for name, blob in expected.items():
        path = repository/name
        require(path.is_file() and not path.is_symlink(), 'Frozen app source file changed type')
        data = path.read_bytes()
        require(hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest() == blob,
                'Frozen app source changed: '+name)
        result[name] = sha(data)
    for name in ['scripts/OwnedWebsiteStores.swift', 'scripts/OwnedExtensionControllers.swift',
                 'scripts/engine/QualificationJournalPath.swift']:
        path = repository/name
        require(path.is_file() and not path.is_symlink(), 'Qualification helper source is unavailable')
        committed = subprocess.run(['git', '-C', str(repository), 'show', 'HEAD:'+name],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        require(committed.returncode == 0 and path.read_bytes() == committed.stdout,
                'Uncommitted qualification helper source changed')
        result[name] = sha(path.read_bytes())
    return result


def compile_qualification_entry(repository, destination, sdk):
    repository, destination, sdk = Path(repository), Path(destination), Path(sdk)
    require(not destination.exists() and not destination.is_symlink(), 'Qualification build destination already exists')
    snapshot = source_snapshot(repository)
    require(sdk.is_dir(), 'Qualification SDK is unavailable')
    settings = sdk/'SDKSettings.json'
    if settings.is_file(): version = str(json.loads(settings.read_text())['Version'])
    else:
        settings = sdk/'SDKSettings.plist'
        require(settings.is_file(), 'Qualification SDK metadata is unavailable')
        version = str(plistlib.loads(settings.read_bytes())['Version'])
    require(version == '26.5', 'Qualification SDK must match the pinned macOS26.5 engine')
    witness = HERE/'FullUBlockQualificationChecks.swift'
    require(witness.is_file() and not witness.is_symlink() and sha(witness.read_bytes()) == WITNESS_SHA,
            'Frozen qualification witness changed')
    require(plistlib.loads((repository/'scripts/Entitlements.plist').read_bytes()) == APP_ENTITLEMENTS,
            'The existing app sandbox policy changed')
    destination.parent.mkdir(parents=True, exist_ok=True)
    environment = {key:value for key,value in os.environ.items()
                   if not key.startswith(('DYLD_', '__XPC_DYLD_'))}
    with tempfile.TemporaryDirectory(prefix='.alcove-qualification-build-', dir=destination.parent) as raw:
        stage = Path(raw)/'build'; stage.mkdir()
        flags = ['-sdk', str(sdk), '-target', 'arm64-apple-macosx26.5', '-module-cache-path', str(stage/'cache'), '-O']
        core = sorted(str(repository/name) for name in snapshot if name.startswith('Sources/BrowserCore/') and name.endswith('.swift'))
        browser = sorted(str(repository/name) for name in snapshot if name.startswith('Sources/Browser/') and name.endswith('.swift') and name != 'Sources/Browser/main.swift')
        helpers = [str(repository/name) for name in snapshot if name.startswith('scripts/')]
        commands = [
            ('core', ['/usr/bin/xcrun', 'swiftc', *flags, '-parse-as-library', '-whole-module-optimization',
                      '-module-name', 'BrowserCore', '-emit-module', '-emit-object', '-emit-module-path',
                      str(stage/'BrowserCore.swiftmodule'), *core, '-o', str(stage/'BrowserCore.o')]),
            ('app', ['/usr/bin/xcrun', 'swiftc', *flags, '-parse-as-library', '-warnings-as-errors',
                     '-Xlinker', '-no_adhoc_codesign', '-Xlinker', '-headerpad_max_install_names',
                     '-D', 'ALCOVE_PACKAGED_QUALIFICATION', '-I', str(stage), *browser, *helpers,
                     str(witness), str(stage/'BrowserCore.o'), '-o', str(stage/'original-main')])]
        for label, args in commands:
            print('QUALIFICATION_COMPILE_STARTED', label, flush=True)
            log = stage/('compile-'+label+'.log')
            try:
                with log.open('wb') as stream:
                    status = subprocess.run(args, cwd=repository, env=environment, stdout=stream,
                                            stderr=subprocess.STDOUT, timeout=420).returncode
            except subprocess.TimeoutExpired as error:
                raise ValueError('Qualification compiler timed out: '+label) from error
            require(status == 0, 'Qualification compiler failed: '+label+'\n'+log.read_text(errors='replace')[-6000:])
            print('QUALIFICATION_COMPILE_FINISHED', label, flush=True)
        require(snapshot == source_snapshot(repository) and sha(witness.read_bytes()) == WITNESS_SHA,
                'Qualification source changed during compilation')
        original = (stage/'original-main').read_bytes()
        info = inspect_image(original)
        verify_entry_platform(info)
        require(not any(kind == 0x1D for kind, _ in info['_commands']),
                'Qualification template entry was unexpectedly sealed before metadata relocation')
        linked_sdk = info['platform']['sdk']
        linked_sdk_label = '.'.join(str(value) for value in (linked_sdk >> 16, (linked_sdk >> 8) & 255, linked_sdk & 255))
        receipt = {'formatVersion':1, 'appSourceBaseline':APP_BASE, 'sourceSHA256':snapshot,
                   'witnessSHA256':WITNESS_SHA, 'sdkSettingsVersion':version,
                   'linkedSDKVersion':linked_sdk_label, 'deploymentTarget':'26.5', 'architecture':'arm64',
                   'entryUnsealed':True,
                   'originalEntrySHA256':sha(original), 'nativeAppQualified':False,
                   'sandboxQualified':False, 'signingPending':True}
        (stage/'build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
        require(not destination.exists() and not destination.is_symlink(), 'Qualification build destination appeared during staging')
        stage.rename(destination)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('prepare-template', 'verify-template'):
        command = commands.add_parser(name)
        for flag in ('engine-receipt', 'runtime', 'assets', 'app', 'manifest'):
            command.add_argument('--'+flag, type=Path, required=True)
        for flag in ('source-package', 'source-git', 'source-contract'):
            command.add_argument('--'+flag, type=Path)
        if name == 'prepare-template':
            command.add_argument('--repository', type=Path, default=HERE.parent.parent)
            command.add_argument('--engine-tree', type=Path, required=True)
            command.add_argument('--build', type=Path, required=True)
            command.add_argument('--sdk', type=Path,
                default=Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'))
        else:
            command.add_argument('--entry', type=Path, required=True)
    args = parser.parse_args()
    witness = HERE/'FullUBlockQualificationChecks.swift'
    assets = {kind:args.assets/('uBlock0_1.76.4.chromium.'+kind) for kind in ASSETS}
    try:
        supplied_source = [args.source_package,args.source_git,args.source_contract]
        require(not any(path is not None for path in supplied_source) or
                all(path is not None for path in supplied_source), 'Complete source package/Git/contract flags are required')
        source_inputs = None if args.source_package is None else {
            'package':args.source_package,'repository':args.source_git,'contract':args.source_contract}
        if args.command == 'prepare-template':
            require(not args.manifest.exists() and not args.manifest.is_symlink(), 'Template manifest destination already exists')
            require(not args.app.exists() and not args.app.is_symlink(), 'Template app destination already exists')
            app, build, manifest = (path.resolve(strict=False) for path in (args.app, args.build, args.manifest))
            require(not manifest.is_relative_to(app) and not manifest.is_relative_to(build) and
                    not build.is_relative_to(app) and not app.is_relative_to(build),
                    'Template app, build and manifest destinations must be separate')
            for path in (app, build, manifest):
                require(all(not path.is_relative_to(source.resolve(strict=False))
                            for source in (args.engine_tree, args.runtime, args.repository/'Sources')),
                        'Template destination is inside an immutable input tree')
            verify_qualification_inputs(witness, assets)
            engine_receipt = json.loads(args.engine_receipt.read_text())
            verify_relocated_runtime_layout(args.engine_tree, engine_receipt, args.runtime)
            if source_inputs is not None:
                for output in (app,build,manifest):
                    require(all(not output.is_relative_to(path.resolve(strict=False)) for path in source_inputs.values()),
                            'Template destination is inside a source input tree')
                source_template_data(source_inputs,args.runtime)
            compiled = compile_qualification_entry(args.repository, args.build, args.sdk)
            result = assemble_unsigned_template(args.engine_tree, engine_receipt, args.runtime,
                args.build/'original-main', compiled['originalEntrySHA256'], witness, assets, args.app,
                source_inputs=source_inputs)
            args.manifest.parent.mkdir(parents=True, exist_ok=True)
            with args.manifest.open('x') as stream: json.dump(result, stream, indent=2); stream.write('\n')
            proof = result['verification']
        else:
            proof = verify_unsigned_template(args.app, json.loads(args.manifest.read_text()),
                json.loads(args.engine_receipt.read_text()), args.runtime, args.entry, witness, assets,
                source_inputs=source_inputs)
        print(json.dumps(proof, sort_keys=True))
        return 0
    except (ValueError, OSError, KeyError) as error:
        print(json.dumps({'error':str(error), 'nativeAppQualified':False, 'sandboxQualified':False,
                          'ordinaryAppQualified':False, 'signingPending':True}, sort_keys=True))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
