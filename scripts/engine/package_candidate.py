"""Prepare a verified engine's bundle layout; native/signing gates remain separate.

The caller must first authenticate and freshly extract the pinned archive with
verified_input.verify_and_extract. A prepared layout is not a runnable app.
"""
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile

from bundle_layout import FRAMEWORK_DIRECTORY, SERVICE_DIRECTORY, SERVICES, map_member
from verified_input import digest, require


def inventory_layout(runtime):
    runtime = runtime.resolve(strict=True)
    members = []
    for path in sorted(runtime.rglob('*')):
        name = path.relative_to(runtime).as_posix()
        item = {'source':name,'destination':map_member(name)}
        if path.is_symlink():
            target = str(path.readlink())
            require(not Path(target).is_absolute() and path.resolve(strict=False).is_relative_to(runtime),
                    'Input runtime link escapes its root')
            service = name.removeprefix('WebKit.framework/Versions/A/XPCServices/')
            if service in SERVICES and name == 'WebKit.framework/Versions/A/XPCServices/'+service:
                require(target == '../../../../'+service and (runtime/service).is_dir(),
                        'Unexpected source service lookup alias')
                item.update(kind='serviceAlias',target=target)
            else:
                optional = (name,target) == ('WebCore.framework/Frameworks','Versions/Current/Frameworks')
                require(path.exists() or optional, 'Unapproved dangling input runtime link')
                item.update(kind='link',target=target)
        elif path.is_dir():
            item.update(kind='directory')
        else:
            require(path.is_file(), 'Unsupported input runtime member type')
            item.update(kind='file',sha256=digest(path),mode=stat.S_IMODE(path.stat().st_mode))
        members.append(item)
    for service in SERVICES:
        if (runtime/service).exists():
            alias = 'WebKit.framework/Versions/A/XPCServices/'+service
            require(any(item['source'] == alias and item['kind'] == 'serviceAlias' for item in members),
                    'Missing source service lookup alias')
    return members


def verify_layout_copy(destination, receipt):
    root = destination.resolve(strict=True)
    require(receipt['formatVersion'] == 1 and receipt['nativeAppQualified'] is False,
            'Invalid prepared-layout receipt')
    expected = set()
    for item in receipt['members'] + receipt['generated']:
        relative = item['destination']
        require(not PurePosixPath(relative).is_absolute() and '..' not in PurePosixPath(relative).parts,
                'Unsafe prepared output member')
        expected.add(relative)
        expected.update(str(parent) for parent in PurePosixPath(relative).parents if str(parent) != '.')
        path = root/relative
        kind = item['kind']
        if kind in ('directory','serviceAlias'):
            require(path.is_dir() and not path.is_symlink(), 'Output directory missing or wrong type')
        elif kind == 'link':
            require(path.is_symlink() and str(path.readlink()) == item['target'], 'Output link content changed')
        else:
            require(path.is_file() and not path.is_symlink(), 'Output file missing or wrong type')
            require(digest(path) == item['sha256'] and stat.S_IMODE(path.stat().st_mode) == item['mode'],
                    'Output file content or mode changed')
    actual = {path.relative_to(root).as_posix() for path in root.rglob('*')}
    require(actual == expected, 'Unexpected or omitted output layout member')
    for path in root.rglob('*'):
        if path.is_symlink():
            require(path.exists() and path.resolve(strict=True).is_relative_to(root),
                    'Output link is dangling or escapes its bundle')
    return {'memberCount':len(receipt['members']),'outputNodeCount':len(actual),
            'layoutCopyVerified':True,'nativeAppQualified':False}


def prepare_runtime_layout(runtime, destination):
    require(not destination.exists() and not destination.is_symlink(), 'Prepared layout destination already exists')
    members = inventory_layout(runtime)
    receipt = {'formatVersion':1,'members':members,'generated':[],
               'nativeAppQualified':False,'ordinaryAppQualified':False}
    destination.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-engine-layout-',dir=destination.parent) as raw:
        stage = Path(raw)/'layout'; stage.mkdir()
        for source in sorted(runtime.iterdir()):
            target = stage/map_member(source.name)
            target.parent.mkdir(parents=True,exist_ok=True)
            if target.is_symlink():
                require(source.name in SERVICES and target == stage/SERVICE_DIRECTORY/source.name,
                        'Unexpected staged service alias collision')
                target.unlink()
            require(not target.exists(), 'Unexpected staged member collision')
            if source.is_dir():
                shutil.copytree(source,target,symlinks=True)
            else:
                shutil.copy2(source,target,follow_symlinks=False)
        if (runtime/'WebCore.framework').exists():
            relative = FRAMEWORK_DIRECTORY+'/WebCore.framework/Versions/A/Frameworks'
            target = stage/relative
            if not target.exists():
                target.mkdir()
                receipt['generated'].append({'destination':relative,'kind':'directory'})
        if (runtime/'ANGLEMetalLib.metallib').exists():
            relative = FRAMEWORK_DIRECTORY+'/ANGLEMetalLib.metallib'
            target = stage/relative; target.parent.mkdir(parents=True,exist_ok=True)
            target.symlink_to('../Resources/AlcoveEngine/ANGLEMetalLib.metallib')
            receipt['generated'].append({'destination':relative,'kind':'link',
                                         'target':'../Resources/AlcoveEngine/ANGLEMetalLib.metallib'})
        receipt['verification'] = verify_layout_copy(stage,receipt)
        require(not destination.exists() and not destination.is_symlink(), 'Prepared layout destination appeared during staging')
        stage.rename(destination)
    return receipt
