"""Authenticate and atomically stage the already qualified engine, without building it.

Archive/link/build-manifest boundaries follow the consumer that actually passed
original full uBlock in run 45539376893. Source wrapper helpers stay pinned.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.dont_write_bytecode = True
PIN = json.loads(Path(__file__).with_name('qualified-runtime.json').read_text())


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    require(path.is_file() and not path.is_symlink(), 'Expected a regular engine input file')
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024*1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify_source_contract(checkout):
    result = subprocess.run(['git', '-C', str(checkout), 'rev-parse', 'HEAD'],
                            text=True, capture_output=True, timeout=30)
    require(result.returncode == 0 and result.stdout.strip() == PIN['wrapperCommit'],
            'Engine helper source revision differs')
    result = subprocess.run(['git', '-C', str(checkout), 'status', '--porcelain',
                             '--untracked-files=all', '--', 'diagnostics'],
                            text=True, capture_output=True, timeout=30)
    require(result.returncode == 0 and not result.stdout, 'Engine helper source revision is dirty')
    diagnostics = checkout/'diagnostics'
    for name in ('prepare-jsc-runtime.py', 'prepare-webkit-dependencies.py', 'built-engine-roots.json'):
        require((diagnostics/name).is_file() and not (diagnostics/name).is_symlink(),
                'Engine helper source revision has an unexpected file type')
    contract = json.loads((diagnostics/'built-engine-roots.json').read_text())
    roots, patches = contract['runtimeRoots'], contract['patches']
    require(contract['formatVersion'] == 1 and contract['webkitRevision'] == PIN['webkitRevision'] and
            len(roots) == len(set(roots)) == PIN['rootCount'], 'Engine root manifest differs')
    require(len(patches) == PIN['patchCount'] and all(digest(diagnostics/name) == sha for name,sha in patches.items()),
            'Engine patch manifest differs')
    return contract


def verify_complete_links(root, members):
    root = root.resolve(strict=True)
    missing = []
    for name, member in members.items():
        if not member.issym():
            continue
        require(not Path(member.linkname).is_absolute(), 'Absolute runtime link')
        target = (root/name).resolve(strict=False)
        require(target.is_relative_to(root), 'Runtime link chain escapes root')
        relative = target.relative_to(root).as_posix()
        if not target.exists():
            require((name, member.linkname, relative) == ('WebCore.framework/Frameworks',
                    'Versions/Current/Frameworks', 'WebCore.framework/Versions/A/Frameworks'),
                    'Unapproved dangling runtime link')
            missing.append(name)
        else:
            require(relative in members, 'Runtime link points to an omitted member')
    require(missing == ['WebCore.framework/Frameworks'], 'Optional runtime link inventory differs')


def verify_build_manifest(record, patches):
    source = record['source']
    require(record['formatVersion'] == source['formatVersion'] == 1 and
            source['wrapperCommit'] == PIN['wrapperCommit'] and source['webkitRevision'] == PIN['webkitRevision'] and
            source['patches'] == patches and source['emptyProductsAtStart'] is True and
            source['sdk'] == PIN['sdk'] and source['appliedSourceSHA256'] == PIN['appliedSourceSHA256'] and
            source['buildCommand'] == ['Tools/Scripts/build-webkit', '--release', '--only=Everything up to WebKit',
                                      'GCC_GENERATE_DEBUGGING_SYMBOLS=NO', 'COMPILER_INDEX_STORE_ENABLE=NO'] and
            record['frameworkSHA256'] == PIN['frameworkSHA256'], 'Engine source/build manifest differs')


def verify_and_extract(archive, contract_checkout, destination):
    require(not destination.exists() and not destination.is_symlink(), 'Engine destination already exists')
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_size == PIN['outerBytes'] and
            digest(archive) == PIN['outerSHA256'], 'Engine input archive differs')
    checkout = contract_checkout.resolve(strict=True)
    contract = verify_source_contract(checkout)
    diagnostics = checkout/'diagnostics'
    spec = importlib.util.spec_from_file_location('alcove_verified_runtime', diagnostics/'prepare-jsc-runtime.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-engine-input-', dir=destination.parent) as raw:
        stage = Path(raw)
        expected = {'AlcoveSource.txt','WebKitSource.txt','PatchChecksums.txt','SHA256SUMS.txt','Alcove-WebKitRuntime.tar.gz'}
        with zipfile.ZipFile(archive) as package:
            entries = package.infolist()
            require(len(entries) == 5 and {item.filename for item in entries} == expected,
                    'Unexpected or duplicate engine archive members')
            for item in entries:
                require(not item.is_dir() and stat.S_IFMT(item.external_attr >> 16) in (0,stat.S_IFREG),
                        'Nonregular engine archive member')
                require(0 < item.file_size <= (512*1024*1024 if item.filename.endswith('.tar.gz') else 256*1024),
                        'Engine archive member exceeds limit')
                with package.open(item) as source, (stage/item.filename).open('xb') as output:
                    shutil.copyfileobj(source, output, length=1024*1024)
        require((stage/'AlcoveSource.txt').read_text() == PIN['wrapperCommit']+'\n' and
                (stage/'WebKitSource.txt').read_text() == PIN['webkitRevision']+'\n', 'Engine archive source manifest differs')
        rows = (stage/'PatchChecksums.txt').read_text().splitlines()
        parsed = [re.fullmatch(r'([0-9a-f]{64})  diagnostics/([A-Za-z0-9_.-]+\.patch)', row) for row in rows]
        require(len(rows) == PIN['patchCount'] and all(parsed) and
                {item[2]:item[1] for item in parsed} == contract['patches'], 'Engine archive patch manifest differs')
        tar = stage/'Alcove-WebKitRuntime.tar.gz'
        require(digest(tar) == PIN['tarSHA256'] and (stage/'SHA256SUMS.txt').read_text().split() ==
                [PIN['tarSHA256'],tar.name], 'Engine runtime archive checksum differs')
        extracted = stage/'runtime'; extracted.mkdir()
        with tarfile.open(tar,'r:gz') as package:
            members = runtime.archive_utils.validate_members(package, exclude_member=lambda _:False,
                                                              validate_link=runtime.validate_runtime_link)
            require(len(members) == PIN['memberCount'] and {name.split('/')[0] for name in members} ==
                    set(contract['runtimeRoots']) | {'AlcoveEngineBuild.json'}, 'Engine runtime graph inventory differs')
            require(not any(any(part.endswith(('.dSYM','.a','.o')) for part in Path(name).parts) for name in members),
                    'Unexpected build product in runtime graph')
            runtime.archive_utils.extract_dependencies(package,members,extracted)
        runtime.verify_links(extracted,members,allowed_roots=set(contract['runtimeRoots']))
        verify_complete_links(extracted,members)
        record = json.loads((extracted/'AlcoveEngineBuild.json').read_text())
        verify_build_manifest(record,contract['patches'])
        for framework, expected_hash in PIN['frameworkSHA256'].items():
            binary = extracted/framework/'Versions/A'/framework.removesuffix('.framework')
            require(binary.stat().st_mode & 0o100 and digest(binary) == expected_hash,
                    'Engine framework bytes or executable mode differ')
        # A fresh destination was required; no partial output is published on validation failure.
        require(not destination.exists() and not destination.is_symlink(), 'Engine destination appeared during import')
        extracted.rename(destination)
    return {**PIN,'runtimeRoot':str(destination.resolve()),'engineInputVerified':True,
            'selfContainedAppQualified':False,'publicAppIntegrationQualified':False}
