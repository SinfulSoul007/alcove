#!/usr/bin/env python3
"""Read-only consumer of one verified source-built engine; never builds WebKit."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import zipfile

sys.dont_write_bytecode = True
REPOSITORY = 'SinfulSoul007/alcove'
REPOSITORY_ID = 1449823948
RUN = 45446004771
WRAPPER = '1fc08bd2013efe318f3d7b7914a24dcf9af07916'
BRANCH = 'research/microtask-entry-settings'
UPSTREAM = '26695efdefc6076049ec50713a2c4e54b90b4d47'
ARTIFACT = 14965369072
ARTIFACT_NAME = 'Alcove-WebKit-microtask-entry-runtime'
OUTER_BYTES = 73446929
OUTER_SHA = '30131eb37220880025acb106279b9ec9a476b212533b23b1dfb4dd63023c5b92'
TAR_SHA = 'add4cd8b373010931b2e8a598f426dfb15243bffb2c1560b81a1f3703346c812'
WITNESS_SHA = '2155d8b27904ca8105f3debee0d3f30242fa387c13d39d0072ed3fcdfea7b725'
SERVER_SHA = 'f794350a5330d0511d5af2024bdbd15fc9e09bf8451aac816ef2947e4840d2ff'
FRAMEWORKS = {
    'JavaScriptCore.framework': 'df403fd0b9399f611302aa11df3db3730972a7e15736935f1535cb69cca21877',
    'WebCore.framework': '7c35f3c07bac9c58a9e13403c6750f434e1c2cf66212ed5b07df4b249834b3f2',
    'WebKit.framework': 'ac499ef069ae0a138f2b099fb84d84be0cc7072fa06a1a929afca3758fd86ba2',
}
ASSETS = {
    'zip': (6149497, '4b1b27ed82e734d508ae6d255933c334f62f256e8a8aece92724b826828e3d5f'),
    'crx': (6054573, 'ee44e69bb7a0e162bf08632929a5059bd676dfaa3ae2267e3c4eb11cc949b21a'),
}
HERE = Path(__file__).resolve().parent


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    require(path.is_file() and not path.is_symlink(), 'Expected regular file: '+str(path))
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.pending')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')
    temporary.replace(path)


def verify_run(run):
    require(run['id'] == RUN and run['status'] == 'completed' and run['conclusion'] == 'success', 'Engine source run did not succeed')
    require(run['head_sha'] == WRAPPER and run['head_branch'] == BRANCH and run['event'] == 'push', 'Engine source run identity changed')
    require(run.get('path') == '.github/workflows/build-microtask-entry.yml', 'Unexpected engine workflow')
    for key in ('repository', 'head_repository'):
        require(run[key]['id'] == REPOSITORY_ID and run[key]['full_name'] == REPOSITORY, 'Foreign engine repository')


def verify_artifact(item):
    require(item['id'] == ARTIFACT and item['name'] == ARTIFACT_NAME and item['expired'] is False, 'Engine artifact unavailable or changed')
    require(item['digest'] == 'sha256:'+OUTER_SHA and item['size_in_bytes'] == OUTER_BYTES, 'Engine artifact digest or size changed')
    run = item['workflow_run']
    require(run['id'] == RUN and run['repository_id'] == run['head_repository_id'] == REPOSITORY_ID, 'Foreign artifact run')
    require(run['head_sha'] == WRAPPER and run['head_branch'] == BRANCH, 'Artifact source changed')


def verify_jobs(jobs):
    require(jobs['total_count'] == len(jobs['jobs']) == 1, 'Unexpected engine job inventory')
    job = jobs['jobs'][0]
    require(job['name'] == 'macos' and job['status'] == 'completed' and job['conclusion'] == 'success', 'Engine native job failed')
    for name in ('Verify 26 microtask entry and realm controls', 'Verify the extension APIs in the built framework', 'Upload the compiled native runtime'):
        matches = [step for step in job['steps'] if step['name'] == name]
        require(len(matches) == 1 and matches[0]['status'] == 'completed' and matches[0]['conclusion'] == 'success', 'Missing successful source gate: '+name)


def api(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/'+REPOSITORY+'/'+endpoint], timeout=90))


def verify_complete_links(root, members):
    root = root.resolve(strict=True)
    missing = []
    for name, member in members.items():
        if not member.issym():
            continue
        require(not Path(member.linkname).is_absolute(), 'Absolute runtime link')
        path = (root/name).resolve(strict=False)
        require(path.is_relative_to(root), 'Runtime link chain escapes root')
        target = path.relative_to(root).as_posix()
        if not path.exists():
            require((name, member.linkname, target) == ('WebCore.framework/Frameworks', 'Versions/Current/Frameworks', 'WebCore.framework/Versions/A/Frameworks'), 'Unapproved dangling runtime link: '+name)
            missing.append(name)
        else:
            require(target in members, 'Runtime link points to an omitted product: '+name)
    require(missing == ['WebCore.framework/Frameworks'], 'Canonical optional bundle link inventory changed')


def verify_engine(archive, engine_source, destination):
    require(subprocess.check_output(['git', '-C', str(engine_source), 'rev-parse', 'HEAD'], text=True).strip() == WRAPPER, 'Engine helper checkout changed')
    subprocess.run(['git', '-C', str(engine_source), 'diff', '--exit-code', 'HEAD', '--', 'diagnostics'], check=True, stdout=subprocess.DEVNULL)
    require(archive.stat().st_size == OUTER_BYTES and digest(archive) == OUTER_SHA, 'Downloaded engine archive changed')
    diagnostics = engine_source/'diagnostics'
    contract = json.loads((diagnostics/'built-engine-roots.json').read_text())
    require(contract['formatVersion'] == 1 and contract['webkitRevision'] == UPSTREAM and len(contract['runtimeRoots']) == len(set(contract['runtimeRoots'])) == 27, 'Unexpected fresh-engine contract')
    patches = contract['patches']
    require(len(patches) == 18 and all(digest(diagnostics/name) == sha for name, sha in patches.items()), 'Engine patch contract changed')
    require(not destination.exists() and not destination.is_symlink(), 'Runtime extraction destination already exists')
    destination.mkdir(parents=True)
    expected = {'AlcoveSource.txt', 'WebKitSource.txt', 'PatchChecksums.txt', 'SHA256SUMS.txt', 'Alcove-WebKitRuntime.tar.gz'}
    artifact = destination.parent/'artifact'
    require(not artifact.exists(), 'Artifact extraction destination already exists')
    artifact.mkdir()
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        require(len(entries) == 5 and {x.filename for x in entries} == expected, 'Unexpected or duplicate engine artifact entries')
        for item in entries:
            require(not item.is_dir() and stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG), 'Nonregular artifact member')
            require(0 < item.file_size <= (512*1024*1024 if item.filename.endswith('.tar.gz') else 256*1024), 'Artifact member exceeds limit')
        package.extractall(artifact)
    require((artifact/'AlcoveSource.txt').read_text() == WRAPPER+'\n', 'Wrapper manifest changed')
    require((artifact/'WebKitSource.txt').read_text() == UPSTREAM+'\n', 'Upstream manifest changed')
    rows = (artifact/'PatchChecksums.txt').read_text().splitlines()
    parsed = [re.fullmatch(r'([0-9a-f]{64})  diagnostics/([A-Za-z0-9_.-]+\.patch)', row) for row in rows]
    require(len(rows) == 18 and all(parsed) and {m[2]:m[1] for m in parsed} == patches, 'Artifact patch inventory changed')
    tar = artifact/'Alcove-WebKitRuntime.tar.gz'
    require(digest(tar) == TAR_SHA and (artifact/'SHA256SUMS.txt').read_text().split() == [TAR_SHA, tar.name], 'Runtime tar checksum changed')
    spec = importlib.util.spec_from_file_location('trusted_runtime_archive', diagnostics/'prepare-jsc-runtime.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    with tarfile.open(tar, 'r:gz') as package:
        members = runtime.archive_utils.validate_members(package, exclude_member=lambda _:False, validate_link=runtime.validate_runtime_link)
        require(len(members) == 10568 and {name.split('/')[0] for name in members} == set(contract['runtimeRoots']) | {'AlcoveEngineBuild.json'}, 'Runtime graph inventory changed')
        require(not any(any(part.endswith(('.dSYM', '.a', '.o')) for part in Path(name).parts) for name in members), 'Unreviewed build product in runtime')
        runtime.archive_utils.extract_dependencies(package, members, destination)
    runtime.verify_links(destination, members, allowed_roots=set(contract['runtimeRoots']))
    verify_complete_links(destination, members)
    record = json.loads((destination/'AlcoveEngineBuild.json').read_text())
    source = record['source']
    require(record['formatVersion'] == source['formatVersion'] == 1 and source['wrapperCommit'] == WRAPPER and source['webkitRevision'] == UPSTREAM, 'Runtime build source changed')
    require(source['patches'] == patches and source['emptyProductsAtStart'] is True and source['sdk'] == '26.5', 'Runtime freshness or patch manifest changed')
    require(source['appliedSourceSHA256'] == '206841ff15632f71f2972f8f530500b00de48b1b4adc71c35a6c5a8d799d6be8', 'Applied source digest changed')
    require(source['buildCommand'] == ['Tools/Scripts/build-webkit', '--release', '--only=Everything up to WebKit', 'GCC_GENERATE_DEBUGGING_SYMBOLS=NO', 'COMPILER_INDEX_STORE_ENABLE=NO'], 'Engine build command changed')
    actual = {}
    for framework in FRAMEWORKS:
        binary = destination/framework/'Versions/A'/framework.removesuffix('.framework')
        require(binary.stat().st_mode & 0o100, 'Framework binary is not executable')
        actual[framework] = digest(binary)
    require(record['frameworkSHA256'] == actual == FRAMEWORKS, 'Fresh source-built framework hashes changed')
    return {'wrapperCommit':WRAPPER, 'webkitRevision':UPSTREAM, 'workflowRun':RUN, 'artifactID':ARTIFACT, 'outerSHA256':OUTER_SHA, 'tarSHA256':TAR_SHA, 'rootCount':27, 'memberCount':len(members), 'patchCount':18, 'frameworkSHA256':actual, 'runtimeRoot':str(destination.resolve()), 'engineVerified':True, 'fullOriginalUBlockQualified':False, 'publicAppIntegrationQualified':False}


def verify_frozen_inputs():
    require(digest(HERE/'FullUBlockDashboardReadyChecks.swift') == WITNESS_SHA, 'Frozen strict witness changed')
    require(digest(HERE/'loopback-server.py') == SERVER_SHA, 'Frozen loopback server changed')


def verify_positive_markers(log):
    for kind in ('zip', 'crx'):
        require(log.splitlines().count('UNMODIFIED_FULL_UBO_ASSET_FILTERING_PROVEN '+kind) == 1, 'Missing original '+kind+' filtering proof')
    require(log.splitlines().count('UNMODIFIED_FULL_UBO_INTEGRATED_FILTERING_PROVEN true') == 1, 'Missing integrated filtering proof')
    for marker in ('UNMODIFIED_FULL_UBO_QUALIFICATION_FAILED', 'UBO_APPLICATION_LOOP_PREMATURE_EXIT', 'UBO_APPLICATION_LOOP_FAILED', 'FAIL:'):
        require(marker not in log, 'Native failure marker: '+marker)
    caps = [json.loads(row.split(' ', 1)[1]) for row in log.splitlines() if row.startswith('UBO_NATIVE_CAPABILITIES ')]
    require(len(caps) == 2 and all(value == {'privacy':'object', 'idle':'function', 'updateEvent':'function', 'navigationTarget':'function'} for value in caps), 'Missing native capability controls')


def prepare(args):
    root = args.work_root.resolve()
    require(not root.exists(), 'Consumer work root already exists')
    root.mkdir(parents=True)
    evidence = root/'evidence'
    evidence.mkdir()
    run = api('actions/runs/'+str(RUN)); verify_run(run)
    metadata = api('actions/artifacts/'+str(ARTIFACT)); verify_artifact(metadata)
    jobs = api('actions/runs/'+str(RUN)+'/jobs?per_page=100'); verify_jobs(jobs)
    write_json(evidence/'source-run.json', run)
    write_json(evidence/'source-artifact.json', metadata)
    write_json(evidence/'source-jobs.json', jobs)
    archive = root/'artifact.zip'
    with archive.open('xb') as stream:
        subprocess.run(['gh', 'api', 'repos/'+REPOSITORY+'/actions/artifacts/'+str(ARTIFACT)+'/zip'], stdout=stream, check=True, timeout=300)
    receipt = verify_engine(archive, args.engine_source.resolve(), root/'runtime')
    receipt['sourceRunAndNativeGatesVerified'] = True
    write_json(evidence/'engine-verified.json', receipt)
    assets = root/'assets'; assets.mkdir()
    for kind, (size, sha) in ASSETS.items():
        filename = 'uBlock0_1.76.4.chromium.'+kind
        destination = assets/filename
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--proto', '=https', '--proto-redir', '=https', '--max-time', '120', '--output', str(destination), 'https://github.com/gorhill/uBlock/releases/download/1.76.4/'+filename], check=True, timeout=130)
        require(destination.stat().st_size == size and digest(destination) == sha, 'Official uBlock asset changed: '+kind)
    verify_frozen_inputs()
    print('VERIFIED_ENGINE_AND_ORIGINAL_UBLOCK_INPUTS true', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare_parser = commands.add_parser('prepare')
    prepare_parser.add_argument('--engine-source', type=Path, required=True)
    prepare_parser.add_argument('--work-root', type=Path, required=True)
    verify_parser = commands.add_parser('verify-local', help='Offline verification only; never runs the native witness')
    verify_parser.add_argument('--engine-source', type=Path, required=True)
    verify_parser.add_argument('--archive', type=Path, required=True)
    verify_parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args)
    else:
        verify_frozen_inputs()
        print(json.dumps(verify_engine(args.archive.resolve(), args.engine_source.resolve(), args.destination.resolve()), sort_keys=True))


if __name__ == '__main__':
    main()
