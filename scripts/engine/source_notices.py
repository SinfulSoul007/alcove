"""Authenticate a complete source archive against Git, preserving original notices.

No archive member is extracted or executed. The upstream archive preserves all
source-level notices; the separate notice index is a filename-based convenience,
not a determination of linked components or of license compliance.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile

from verified_input import PIN, digest, require, verify_build_manifest, verify_source_contract


def source_tree(repository, revision):
    require(re.fullmatch(r'[0-9a-f]{40}', revision), 'Invalid source revision')
    command = ['git', '-C', str(repository)]
    result = subprocess.run(command + ['rev-parse', '--verify', revision+'^{commit}'],
                            capture_output=True, timeout=30)
    require(result.returncode == 0 and result.stdout.decode().strip() == revision,
            'Source revision is unavailable')
    result = subprocess.run(command + ['ls-tree', '-rz', '--full-tree', revision],
                            capture_output=True, timeout=120)
    require(result.returncode == 0, 'Cannot enumerate source revision')
    entries = {}
    for entry in result.stdout.split(b'\0'):
        if not entry: continue
        header, raw_name = entry.split(b'\t', 1)
        mode, kind, oid = header.decode('ascii').split()
        name = raw_name.decode('utf-8')
        require(kind == 'blob' and mode in ('100644', '100755', '120000'),
                'Unsupported source tree type or mode')
        require(name not in entries and canonical_path(name), 'Invalid source tree path')
        entries[name] = (mode, oid)
    require(0 < len(entries) <= 1000000, 'Invalid source member count')
    return entries


def canonical_path(name):
    return (isinstance(name, str) and 0 < len(name.encode('utf-8')) <= 4096 and
            not name.startswith('/') and '\\' not in name and
            all(part not in ('', '.', '..') for part in name.split('/')) and
            not any(ord(c) < 32 or ord(c) == 127 for c in name))


def notice_name(name):
    return re.fullmatch(r'(?:LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|PATENTS?)(?:[._-].*)?',
                        PurePosixPath(name).name, re.IGNORECASE) is not None


def verify_source_archive(archive, repository, revision, *, notice_directory=None):
    """Compare every regular byte/link target and executable bit to the Git tree.

    Symlink targets are authenticated as data and never followed, including test
    fixtures whose original links intentionally point outside their directory.
    """
    entries = source_tree(repository, revision)
    require(archive.is_file() and not archive.is_symlink(), 'Expected regular source archive')
    before = digest(archive)
    parents = {''}
    for name in entries:
        parent = PurePosixPath(name).parent
        while str(parent) != '.':
            parents.add(str(parent)); parent = parent.parent
    prefix = 'WebKit-'+revision
    seen = set(); seen_directories = set(); total = 0; notices = []
    with tarfile.open(archive, 'r|*') as source:
        for item in source:
            archive_name = item.name.rstrip('/') if item.isdir() else item.name
            require(archive_name == prefix or archive_name.startswith(prefix+'/'),
                    'Unexpected source archive member path')
            name = archive_name[len(prefix)+1:] if archive_name != prefix else ''
            if item.isdir():
                require((not name or canonical_path(name)) and name in parents and
                        name not in seen_directories, 'Invalid or duplicate source directory path')
                seen_directories.add(name)
                continue
            require(canonical_path(name) and name in entries, 'Unexpected source member path or inventory')
            require(name not in seen, 'Duplicate source archive member')
            seen.add(name)
            mode, oid = entries[name]
            require(item.size >= 0 and item.size <= 512*1024*1024, 'Oversized source member')
            total += item.size
            require(total <= 20*1024*1024*1024, 'Oversized complete source archive')
            if mode == '120000':
                require(item.issym() and item.size == 0, 'Source link type differs')
                data = item.linkname.encode('utf-8')
                require(len(data) <= 4096, 'Oversized source link')
                blob = hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
                require(blob == oid, 'Source link blob differs')
                continue
            require(item.isfile(), 'Expected regular source member type')
            require(item.mode == (0o755 if mode == '100755' else 0o644), 'Source member mode differs')
            content = source.extractfile(item)
            require(content is not None, 'Missing source bytes')
            sha1 = hashlib.sha1(b'blob '+str(item.size).encode()+b'\0')
            sha256 = hashlib.sha256(); count = 0
            selected = notice_name(name)
            require(not selected or item.size <= 8*1024*1024, 'Oversized source notice')
            notice = bytearray() if selected else None
            for chunk in iter(lambda: content.read(1024*1024), b''):
                count += len(chunk); sha1.update(chunk); sha256.update(chunk)
                if selected: notice.extend(chunk)
            require(count == item.size and sha1.hexdigest() == oid, 'Source bytes differ from Git blob: '+name)
            if selected:
                notices.append({'path': name, 'bytes': count, 'sha256': sha256.hexdigest()})
                if notice_directory is not None:
                    output = notice_directory/name
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with output.open('xb') as sink: sink.write(notice)
    require(seen == set(entries), 'Source archive inventory has missing members')
    require(digest(archive) == before, 'Source archive changed during verification')
    return {'formatVersion': 1, 'revision': revision, 'sourceMembers': len(seen),
            'sourceBytes': total, 'archiveSHA256': before, 'notices': sorted(notices, key=lambda n:n['path']),
            'noticeIndexScope': 'Filename candidates; full archive preserves all source notices',
            'nativeAppQualified': False, 'ordinaryAppQualified': False, 'signingPending': True}


def prepare_source_notices(archive, repository, revision, destination):
    require(not destination.exists() and not destination.is_symlink(), 'Source destination already exists')
    require(not destination.resolve().is_relative_to(repository.resolve()), 'Source destination is inside Git input')
    require(archive.is_file() and not archive.is_symlink(), 'Expected regular source archive')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-source-', dir=destination.parent) as temporary:
        stage = Path(temporary)/'source'; stage.mkdir()
        original_sha = digest(archive)
        staged_archive = stage/'WebKit-source.tar.gz'; shutil.copyfile(archive, staged_archive)
        receipt = verify_source_archive(staged_archive, repository, revision, notice_directory=stage/'notices')
        require(receipt['archiveSHA256'] == original_sha and digest(archive) == original_sha,
                'Source archive changed during publication')
        (stage/'source-notices.json').write_text(json.dumps(receipt, indent=2)+'\n')
        require(not destination.exists() and not destination.is_symlink(), 'Source destination already exists')
        stage.rename(destination)
    return receipt


def verify_modified_source(repository, revision, patches, expected_sha256):
    """Reconstruct producer changes in an isolated index, never its worktree/ref."""
    require(re.fullmatch(r'[0-9a-f]{40}', revision) and
            re.fullmatch(r'[0-9a-f]{64}', expected_sha256), 'Invalid modified source revision or digest')
    for patch in patches:
        require(patch.is_file() and not patch.is_symlink(), 'Expected regular source patch')
    with tempfile.TemporaryDirectory(prefix='alcove-source-index-') as temporary:
        environment = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary)/'index'))
        command = ['git', '-C', str(repository), '--attr-source='+revision, '-c', 'core.quotePath=true',
                   '-c', 'core.fileMode=true', '-c', 'color.ui=false',
                   '-c', 'diff.algorithm=myers', '-c', 'diff.mnemonicPrefix=false']
        read = subprocess.run(command+['read-tree', revision], env=environment,
                              capture_output=True, timeout=120)
        require(read.returncode == 0, 'Cannot read modified source revision')
        for patch in patches:
            apply = subprocess.run(command+['apply', '--cached', '--binary', '--', str(patch.resolve())],
                                   env=environment, capture_output=True, timeout=120)
            require(apply.returncode == 0, 'Source patch does not apply in producer order: '+patch.name)
        diff = subprocess.run(command+['diff', '--cached', '--binary', '--no-ext-diff', '--no-textconv',
                                      '--no-renames', '--src-prefix=a/', '--dst-prefix=b/', revision],
                              env=environment, capture_output=True, timeout=120)
        require(diff.returncode == 0 and hashlib.sha256(diff.stdout).hexdigest() == expected_sha256,
                'Modified source diff differs from producer')
        return diff.stdout


def prepare_engine_source(archive, contract_checkout, runtime, destination, *, source_repository=None):
    """Prepare pinned baseline source, exact patches, producer recipe and notices.

    This is source distribution material only. It does not sign, run, license-
    qualify or publish an engine binary or change ordinary-app capabilities.
    """
    require(not destination.exists() and not destination.is_symlink(), 'Source destination already exists')
    contract = verify_source_contract(contract_checkout)
    require(source_repository is not None, 'Upstream source repository is required')
    require(not destination.resolve().is_relative_to(source_repository.resolve()) and
            not destination.resolve().is_relative_to(contract_checkout.resolve()) and
            not destination.resolve().is_relative_to(runtime.resolve()), 'Source destination is inside input')
    manifest_path = runtime/'AlcoveEngineBuild.json'
    require(manifest_path.is_file() and not manifest_path.is_symlink(), 'Missing regular engine build manifest')
    manifest_data = manifest_path.read_bytes()
    record = json.loads(manifest_data)
    verify_build_manifest(record, contract['patches'])
    workflow_path = '.github/workflows/build-microtask-entry.yml'
    workflow = subprocess.run(['git', '-C', str(contract_checkout), 'show',
                               PIN['wrapperCommit']+':'+workflow_path],
                              capture_output=True, timeout=30)
    require(workflow.returncode == 0 and workflow.stdout, 'Pinned engine build recipe is missing')
    order_lines = re.findall(r'^\s*for name in ([^;\n]+); do$', workflow.stdout.decode('utf-8'), re.MULTILINE)
    require(len(order_lines) == 1, 'Pinned engine patch order is missing')
    patch_order = [name+'.patch' for name in order_lines[0].split()]
    require(len(patch_order) == len(set(patch_order)) == PIN['patchCount'] and
            set(patch_order) == set(contract['patches']), 'Pinned engine patch order differs')
    modified = verify_modified_source(source_repository, PIN['webkitRevision'],
                [contract_checkout/'diagnostics'/name for name in patch_order], PIN['appliedSourceSHA256'])
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-engine-source-', dir=destination.parent) as temporary:
        stage = Path(temporary)/'package'; stage.mkdir()
        receipt = prepare_source_notices(archive, source_repository, PIN['webkitRevision'], stage/'upstream')
        patch_directory = stage/'patches'; patch_directory.mkdir()
        for name, sha in sorted(contract['patches'].items()):
            data = (contract_checkout/'diagnostics'/name).read_bytes()
            require(hashlib.sha256(data).hexdigest() == sha, 'Engine patch changed during source preparation')
            (patch_directory/name).write_bytes(data)
        (stage/'AlcoveEngineBuild.json').write_bytes(manifest_data)
        (stage/'modified-source.patch').write_bytes(modified)
        (stage/'build-microtask-entry.yml').write_bytes(workflow.stdout)
        (stage/'README.txt').write_text(
            'Alcove experimental WebKit engine source material\n\n'
            'The upstream archive is the complete unmodified Git tree at '+PIN['webkitRevision']+'.\n'
            'Original source bytes, file modes, link targets and notice files were verified against Git.\n'
            'All 18 modifications are supplied as unchanged patches; their hashes are in the manifest.\n'
            'The copied pinned producer workflow records patch order, configuration and build commands.\n'
            'Apply patches in that workflow order, not filename order. The build used SDK '+PIN['sdk']+'.\n'
            'modified-source.patch reconstructs the exact combined producer diff; its digest was verified.\n'
            'AlcoveEngineBuild.json records the original producer source/build and framework hashes.\n\n'
            'Upstream: https://github.com/WebKit/WebKit/tree/'+PIN['webkitRevision']+'\n'
            'Producer: https://github.com/SinfulSoul007/alcove/tree/'+PIN['wrapperCommit']+'\n'
            'Bundle transformation and installation references: scripts/engine/README.md and\n'
            'docs/embedded-webkit-verification.md on feature/embedded-webkit in that repository.\n\n'
            'The notices directory is a filename-based index and can include test/tool notices.\n'
            'The full archive retains all source-level notices, including those in code comments.\n'
            'This material alone does not establish license compliance, successful rebuilding,\n'
            'final signing, native qualification, ordinary-app support or release readiness.\n')
        receipt = dict(receipt, wrapperCommit=PIN['wrapperCommit'], patches=contract['patches'], patchOrder=patch_order,
                       appliedSourceSHA256=PIN['appliedSourceSHA256'],
                       buildRecipeSHA256=hashlib.sha256(workflow.stdout).hexdigest(),
                       engineBuildManifestSHA256=hashlib.sha256(manifest_data).hexdigest())
        (stage/'engine-source.json').write_text(json.dumps(receipt, indent=2)+'\n')
        verify_source_contract(contract_checkout)
        require(manifest_path.read_bytes() == manifest_data, 'Engine build manifest changed during preparation')
        require(not destination.exists() and not destination.is_symlink(), 'Source destination already exists')
        stage.rename(destination)
    return receipt


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--source-git', required=True, type=Path)
    parser.add_argument('--contract-checkout', required=True, type=Path)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    try:
        receipt = prepare_engine_source(args.archive, args.contract_checkout, args.runtime,
                                        args.destination, source_repository=args.source_git)
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error)+'\n')
    print(json.dumps({key: receipt[key] for key in ('revision', 'sourceMembers', 'archiveSHA256',
                     'nativeAppQualified', 'ordinaryAppQualified', 'signingPending')}))
