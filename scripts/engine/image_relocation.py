"""Verify allowlisted metadata relocation of the authenticated, owned engine.

This check neither loads images nor signs them. Apple tooling performs the
relocation; the result is still unqualified until the separate signing and
native app gates pass.
"""
import os
import stat
import subprocess
import tempfile
from pathlib import Path

from macho_metadata import DYLIB_COMMANDS, ENVIRONMENT, command_string, digest, inspect_image, approved_environment, require, remove_developer_environment, verify_derivation

RPATH = 0x8000001C


def relocate_image_copy(source, destination, plan, expected_input_sha256):
    source, destination = Path(source), Path(destination)
    require(not destination.exists() and not destination.is_symlink(), 'Relocation destination already exists')
    require(source.is_file() and not source.is_symlink(), 'Expected a regular input file, not a link')
    before = source.read_bytes()
    mode = stat.S_IMODE(source.stat().st_mode)
    require(digest(before) == expected_input_sha256, 'Relocation input digest changed')
    clean = remove_developer_environment(before)
    verify_derivation(before, clean, {'removeDeveloperEnvironment': True})
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-engine-image-', dir=destination.parent) as raw:
        image = Path(raw)/'image'
        image.write_bytes(clean)
        image.chmod(mode)
        args = ['install_name_tool']
        if plan['identity'] is not None:
            args += ['-id', plan['identity']]
        for old, new in plan['changes'].items():
            args += ['-change', old, new]
        for old in plan['removeRpaths']:
            args += ['-delete_rpath', old]
        args += ['-add_rpath', plan['addRpath'], str(image)]
        try:
            result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError('Apple relocation tool could not finish') from error
        require(result.returncode == 0, 'Apple relocation tool rejected the image')
        receipt = verify_relocation(before, image.read_bytes(), plan)
        require(stat.S_IMODE(image.stat().st_mode) == mode, 'Relocated image file mode changed')
        require(not source.is_symlink() and source.read_bytes() == before and
                stat.S_IMODE(source.stat().st_mode) == mode, 'Relocation input file changed')
        # Same-filesystem link publication is atomic and cannot replace an
        # output that appeared concurrently. The temporary name is then removed.
        try:
            os.link(image, destination)
        except FileExistsError as error:
            raise ValueError('Relocation destination appeared during staging') from error
        return receipt


def verify_relocation(before, after, plan):
    original, derived = inspect_image(before), inspect_image(after)
    require(len(before) == len(after), 'Image content length changed')
    require(before[:16] == after[:16] and before[24:32] == after[24:32],
            'Image header identity changed')
    require(original['sections'] == derived['sections'], 'Executable/data section content changed')
    require(original['platform'] == derived['platform'], 'Platform load command changed')
    approved_environment(original['environment'])
    require(not derived['environment'], 'Developer environment load commands remain')
    require(plan['removeRpaths'] == original['rpaths'], 'Relocation plan rpaths do not match input')
    require(set(plan['changes']).issubset(original['dependencies']),
            'Relocation plan contains an absent dependency')
    require((original['identity'] is None) == (plan['identity'] is None),
            'Relocation plan changes library identity presence')
    require(isinstance(plan['addRpath'], str) and
            (plan['addRpath'] == '@loader_path' or plan['addRpath'].startswith('@loader_path/')),
            'Relocation plan needs a loader-relative search path')
    require(derived['rpaths'] == [plan['addRpath']], 'Unplanned runtime search rpath')

    def commands(image, expected):
        values = []
        for kind, raw in image['_commands']:
            if kind in (ENVIRONMENT, RPATH):
                continue
            if kind in DYLIB_COMMANDS:
                name = command_string(raw, 24)
                if expected:
                    name = plan['identity'] if kind == 0xD else plan['changes'].get(name, name)
                # The string allocation may change. Timestamps, versions,
                # dependency kind and dependency order must remain identical.
                values.append((kind, raw[12:24], name))
            else:
                values.append((kind, raw))
        return values

    require(commands(original, True) == commands(derived, False), 'Unapproved load command change')
    old_end, new_end = original['tableEnd'], derived['tableEnd']
    limit = max(old_end, new_end)
    if new_end > old_end:
        require(before[old_end:new_end] == bytes(new_end-old_end),
                'Insufficient empty load command padding')
    else:
        require(after[new_end:old_end] == bytes(old_end-new_end),
                'Removed load command padding is not zeroed')
    require(before[limit:] == after[limit:], 'Image content outside load commands changed')
    return {'inputSHA256': digest(before), 'outputSHA256': digest(after),
            'sectionCount': len(original['sections']),
            'sectionBytesAndOffsetsUnchanged': True,
            'removedEnvironmentCommands': len(original['environment']),
            'dependencyChanges': len(plan['changes']),
            'nativeAppQualified': False, 'ordinaryAppQualified': False}
