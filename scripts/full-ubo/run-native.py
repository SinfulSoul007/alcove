#!/usr/bin/env python3
"""Bounded, token-free native qualification and ownership-journal recovery."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('hosted_consumer', HERE/'hosted-qualification.py')
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)


def child_environment(root):
    # Framework paths are reconstructed AFTER this interpreter starts (SIP can
    # sanitize incoming DYLD variables). No CI authentication enters the child.
    environment = {key: os.environ[key] for key in ('PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', '__CF_USER_TEXT_ENCODING') if key in os.environ}
    temporary = root/'owned-tmp'; temporary.mkdir(exist_ok=True)
    runtime = str((root/'runtime').resolve(strict=True))
    environment.update(TMPDIR=str(temporary)+'/', DYLD_FRAMEWORK_PATH=runtime,
                       __XPC_DYLD_FRAMEWORK_PATH=runtime, ALCOVE_EXPECT_WEBKIT_ROOT=runtime)
    return environment


def verify_prepared(root):
    consumer.verify_frozen_inputs()
    receipt = json.loads((root/'evidence/engine-verified.json').read_text())
    consumer.require(receipt['engineVerified'] is True and receipt['sourceRunAndNativeGatesVerified'] is True, 'Missing verified source engine receipt')
    consumer.require(receipt['wrapperCommit'] == consumer.WRAPPER and receipt['outerSHA256'] == consumer.OUTER_SHA and receipt['artifactID'] == consumer.ARTIFACT, 'Prepared engine identity changed')
    consumer.require(receipt['runtimeRoot'] == str((root/'runtime').resolve(strict=True)), 'Prepared engine path changed')
    for framework, expected in consumer.FRAMEWORKS.items():
        consumer.require(consumer.digest(root/'runtime'/framework/'Versions/A'/framework.removesuffix('.framework')) == expected, 'Prepared framework changed')
    return receipt


def bounded(command, logfile, environment, timeout):
    process = None
    with logfile.open('w') as stream:
        try:
            process = subprocess.Popen(command, cwd=REPO, env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic()+timeout
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError('Owned command exceeded '+str(timeout)+' seconds: '+Path(command[0]).name)
                if logfile.stat().st_size > 32*1024*1024:
                    raise RuntimeError('Owned command exceeded bounded log size')
                time.sleep(0.1)
            consumer.require(logfile.stat().st_size <= 32*1024*1024, 'Owned command exceeded bounded log size')
            return process.returncode
        finally:
            if process is not None:
                # Group is created solely for this owned test command. Stop its
                # children on failure/timeout before recovering owned storage.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)


def cleanup(root, logname='cleanup.log'):
    probe = root/'harness/probe'
    if not probe.exists():
        return True
    verify_prepared(root)
    environment = child_environment(root)
    status = bounded([str(probe), '--cleanup-owned-stores'], root/'evidence'/logname, environment, 90)
    journals = [probe.with_name(probe.name+suffix) for suffix in ('.owned-stores.json', '.owned-extension-controllers.json')]
    result = status == 0 and not any(path.exists() for path in journals)
    if result and (root/'owned-tmp').exists():
        shutil.rmtree(root/'owned-tmp')
    print('OWNED_UBO_STORAGE_CLEANUP_PROVEN', str(result).lower(), flush=True)
    return result


def compile_harness(root, environment):
    consumer.require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Hosted arm64 macOS required')
    consumer.require(subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip().split('.')[0] == '26', 'Hosted macOS 26 required')
    consumer.require(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], env=environment, text=True).strip() == '26.5', 'SDK 26.5 required')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=environment, text=True).strip()
    harness = root/'harness'; harness.mkdir()
    cache = root/'module-cache'; cache.mkdir()
    # This only validates/copies existing app resources and compiles the current
    # BrowserCore plus the test executable; it never invokes the app build script.
    subprocess.run([sys.executable, str(REPO/'scripts/refresh-website-protection.py'), '--verify', str(REPO/'Resources/WebsiteProtection')], check=True, env=environment, timeout=30)
    shutil.copytree(REPO/'Resources/WebsiteProtection', harness/'WebsiteProtection')
    flags = ['xcrun', 'swiftc', '-sdk', sdk, '-module-cache-path', str(cache), '-target', 'arm64-apple-macosx14.0']
    core = sorted(str(path) for path in (REPO/'Sources/BrowserCore').glob('*.swift'))
    command = flags+['-emit-module', '-emit-library', '-enable-testing', '-module-name', 'BrowserCore', *core,
                     '-o', str(harness/'libBrowserCore.dylib'), '-emit-module-path', str(harness/'BrowserCore.swiftmodule')]
    consumer.require(bounded(command, root/'evidence/compile-core.log', environment, 420) == 0, 'BrowserCore harness compilation failed')
    sources = sorted(str(path) for path in (REPO/'Sources/Browser').glob('*.swift') if path.name != 'main.swift')
    command = flags+['-warnings-as-errors', '-parse-as-library', '-I', str(harness), '-L', str(harness), '-lBrowserCore',
                     '-Xlinker', '-rpath', '-Xlinker', str(harness), *sources,
                     str(HERE/'FullUBlockDashboardReadyChecks.swift'), str(REPO/'scripts/OwnedWebsiteStores.swift'),
                     str(REPO/'scripts/OwnedExtensionControllers.swift'), '-o', str(harness/'probe')]
    consumer.require(bounded(command, root/'evidence/compile-witness.log', environment, 420) == 0, 'Frozen full uBlock harness compilation failed')


def execute(root):
    evidence = root/'evidence'
    evidence.mkdir(parents=True, exist_ok=True)
    result = {'qualified':False, 'fullOriginalUBlockQualified':False, 'publicAppIntegrationQualified':False,
              'cleanupSucceeded':False, 'witnessSHA256':consumer.WITNESS_SHA,
              'qualifiedAppBase':'efeedfd8bf7e64284762bbcaa3bc8ed4a6134ea9',
              'qualificationScope':'Test executable compiled from current app sources, verified source-built engine, unchanged original upstream ZIP and CRX'}
    consumer.write_json(evidence/'qualification.json', result)
    server = None
    server_log = None
    failure = None
    try:
        verify_prepared(root)
        result['consumerCommit'] = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip()
        subprocess.run(['git', '-C', str(REPO), 'diff', '--exit-code', 'efeedfd8bf7e64284762bbcaa3bc8ed4a6134ea9', '--', 'Sources', 'Resources', 'scripts/OwnedWebsiteStores.swift', 'scripts/OwnedExtensionControllers.swift'], check=True, stdout=subprocess.DEVNULL)
        environment = child_environment(root)
        compile_harness(root, environment)
        assets = []
        for kind, (size, sha) in consumer.ASSETS.items():
            path = root/'assets'/('uBlock0_1.76.4.chromium.'+kind)
            consumer.require(path.stat().st_size == size and consumer.digest(path) == sha, 'Original uBlock asset changed')
            assets.append(str(path))
        portfile = root/'loopback-port'
        consumer.require(not portfile.exists(), 'Loopback port file already exists')
        server_log = (evidence/'loopback-server.log').open('w')
        server = subprocess.Popen([sys.executable, '-B', str(HERE/'loopback-server.py'), str(portfile)], cwd=REPO, env=environment, stdout=server_log, stderr=subprocess.STDOUT)
        deadline = time.monotonic()+10
        while not portfile.exists() or portfile.stat().st_size == 0:
            consumer.require(server.poll() is None and time.monotonic() < deadline, 'Owned loopback server failed to start')
            time.sleep(0.05)
        port = int(portfile.read_text())
        consumer.require(0 < port < 65536, 'Invalid owned loopback port')
        environment['ALCOVE_UBO_LOOPBACK_URL'] = 'http://127.0.0.1:'+str(port)+'/'
        native_log = evidence/'native-witness.log'
        status = bounded([str(root/'harness/probe'), *assets], native_log, environment, 480)
        result['nativeExitCode'] = status
        consumer.require(status == 0, 'Native strict witness returned failure')
        log = native_log.read_text()
        consumer.verify_positive_markers(log)
        frameworks = [row.removeprefix('ACTUAL_WEBKIT_FRAMEWORK ') for row in log.splitlines() if row.startswith('ACTUAL_WEBKIT_FRAMEWORK ')]
        runtime = (root/'runtime').resolve(strict=True)
        consumer.require(len(frameworks) == 1 and Path(frameworks[0]).resolve(strict=True).is_relative_to(runtime), 'Actual native WebKit root differs')
        result['positiveMarkersVerified'] = True
        result['actualWebKitFramework'] = frameworks[0]
    except BaseException as error:
        failure = error
        result['failure'] = type(error).__name__+': '+str(error)
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=5)
        if server_log is not None:
            server_log.close()
        try:
            result['cleanupSucceeded'] = cleanup(root)
        except BaseException as error:
            result['cleanupFailure'] = type(error).__name__+': '+str(error)
        result['qualified'] = result['fullOriginalUBlockQualified'] = failure is None and result.get('positiveMarkersVerified') is True and result['cleanupSucceeded'] is True
        consumer.write_json(evidence/'qualification.json', result)
        print(json.dumps(result, sort_keys=True), flush=True)
        for filename in ('compile-core.log', 'compile-witness.log', 'native-witness.log', 'cleanup.log'):
            path = evidence/filename
            if path.exists():
                print('\n'+filename+' (last 100 lines):', flush=True)
                print('\n'.join(path.read_text(errors='replace').splitlines()[-100:]), flush=True)
    return 0 if result['qualified'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['run', 'cleanup'])
    parser.add_argument('--work-root', type=Path, required=True)
    args = parser.parse_args()
    root = args.work_root.resolve()
    # Workflow cancellation must pass through finally for owned storage cleanup.
    def interrupted(signum, _frame):
        raise SystemExit('Received signal '+str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    if args.command == 'run':
        return execute(root)
    result = False
    try:
        result = cleanup(root, 'recovery-cleanup.log')
    except BaseException as error:
        print('OWNED_UBO_STORAGE_RECOVERY_FAILED', type(error).__name__, str(error), flush=True)
    receipt = root/'evidence/qualification.json'
    if receipt.exists():
        previous = json.loads(receipt.read_text())
        previous['recoveryCleanupSucceeded'] = result
        if not result:
            previous.update(qualified=False, fullOriginalUBlockQualified=False, cleanupSucceeded=False)
        consumer.write_json(receipt, previous)
    return 0 if result else 1


if __name__ == '__main__':
    sys.exit(main())
