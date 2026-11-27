"""Prepare a verified engine's bundle layout; native/signing gates remain separate.

The caller must first authenticate and freshly extract the pinned archive with
verified_input.verify_and_extract. A prepared layout is not a runnable app.
"""
from pathlib import Path, PurePosixPath
import copy
import shutil
import stat
import tempfile

from bundle_layout import FRAMEWORK_DIRECTORY, SERVICE_DIRECTORY, SERVICES, map_member, plan_relocations, is_owned_reference
from image_relocation import relocate_image_copy, verify_relocation
from macho_metadata import inspect_image
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


def runtime_images(runtime, members):
    images = []
    magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
             b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
             b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
    for member in members:
        if member['kind'] != 'file':
            continue
        path = runtime/member['source']
        with path.open('rb') as file:
            prefix = file.read(4)
        if prefix in magic:
            images.append({**inspect_image(path.read_bytes()), 'path':member['source']})
    require(images, 'No engine image inventory')
    return images


def verify_relocated_runtime_layout(destination, receipt, runtime):
    root, runtime = destination.resolve(strict=True), runtime.resolve(strict=True)
    require(receipt['formatVersion'] == 1 and receipt['nativeAppQualified'] is False and
            receipt['ordinaryAppQualified'] is False and receipt['signingPending'] is True,
            'Invalid relocated layout receipt')
    original = receipt['inputLayout']
    require(original['members'] == inventory_layout(runtime), 'Engine input provenance changed')
    generated = []
    destinations = {member['destination'] for member in original['members']}
    optional = FRAMEWORK_DIRECTORY+'/WebCore.framework/Versions/A/Frameworks'
    if (runtime/'WebCore.framework').is_dir() and optional not in destinations:
        generated.append({'destination':optional, 'kind':'directory'})
    if (runtime/'ANGLEMetalLib.metallib').is_file():
        generated.append({'destination':FRAMEWORK_DIRECTORY+'/ANGLEMetalLib.metallib', 'kind':'link',
                          'target':'../Resources/AlcoveEngine/ANGLEMetalLib.metallib'})
    require(original['generated'] == generated, 'Unexpected generated layout provenance')
    verify_layout_copy(root, receipt['outputLayout'])
    images = runtime_images(runtime, original['members'])
    plans = plan_relocations(images)
    records = receipt['images']
    require(len(records) == len(images) and {record['source'] for record in records} == set(plans),
            'Incomplete or duplicate image receipt inventory')
    records = {record['source']:record for record in records}
    expected = copy.deepcopy(original)
    output_members = {member['source']:member for member in expected['members']}
    embedded = {}
    observed = []
    for image in images:
        name = image['path']; plan = plans[name]; record = records[name]
        require(record['plan'] == plan and record['destination'] == plan['destination'],
                'Image relocation plan receipt changed')
        path = root/plan['destination']
        proof = verify_relocation((runtime/name).read_bytes(), path.read_bytes(), plan)
        require(record['proof'] == proof, 'Image derivation receipt changed')
        output_members[name]['sha256'] = proof['outputSHA256']
        info = inspect_image(path.read_bytes())
        if info['identity'] is not None:
            require(info['identity'] not in embedded, 'Duplicate relocated image identity')
            embedded[info['identity']] = path
        observed.append((path, info))
    require(receipt['outputLayout'] == expected, 'Relocated output provenance receipt changed')
    frameworks = (root/FRAMEWORK_DIRECTORY).resolve(strict=True)
    for path, info in observed:
        require(len(info['rpaths']) == 1 and info['rpaths'][0].startswith('@loader_path'),
                'Unplanned relocated image rpath')
        relative = info['rpaths'][0].removeprefix('@loader_path').lstrip('/')
        require((path.parent/relative).resolve(strict=True) == frameworks,
                'Relocated loader search path misses bundle frameworks')
        for dependency in info['dependencies']:
            if dependency.startswith('@rpath/'):
                target = embedded.get(dependency)
                require(target is not None, 'Unmapped relocated engine dependency')
                resolved = (frameworks/dependency.removeprefix('@rpath/')).resolve(strict=True)
                require(resolved.is_relative_to(frameworks) and resolved == target.resolve(strict=True),
                        'Relocated engine dependency escapes or resolves to another image')
            else:
                require(dependency.startswith(('/System/Library/', '/usr/lib/')) and
                        not is_owned_reference(dependency), 'Unmapped relocated image dependency')
    return {'imageCount':len(images), 'dependencyClosureVerified':True,
            'resourceProvenanceVerified':True, 'nativeAppQualified':False,
            'ordinaryAppQualified':False, 'signingPending':True}


def prepare_relocated_runtime_layout(runtime, destination):
    runtime, destination = Path(runtime), Path(destination)
    require(not destination.exists() and not destination.is_symlink(), 'Relocated layout destination already exists')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-engine-relocation-', dir=destination.parent) as raw:
        scratch = Path(raw); stage = scratch/'layout'
        original = prepare_runtime_layout(runtime, stage)
        images = runtime_images(runtime, original['members'])
        plans = plan_relocations(images)
        output = copy.deepcopy(original)
        members = {member['source']:member for member in output['members']}
        records = []
        for image in images:
            name = image['path']; plan = plans[name]
            transformed = scratch/'images'/plan['destination']
            proof = relocate_image_copy(runtime/name, transformed, plan, members[name]['sha256'])
            transformed.replace(stage/plan['destination'])
            members[name]['sha256'] = proof['outputSHA256']
            records.append({'source':name, 'destination':plan['destination'], 'plan':plan, 'proof':proof})
        receipt = {'formatVersion':1, 'inputLayout':original, 'outputLayout':output,
                   'images':records, 'nativeAppQualified':False, 'ordinaryAppQualified':False,
                   'signingPending':True}
        receipt['verification'] = verify_relocated_runtime_layout(stage, receipt, runtime)
        require(not destination.exists() and not destination.is_symlink(),
                'Relocated layout destination appeared during staging')
        stage.rename(destination)
    return receipt
