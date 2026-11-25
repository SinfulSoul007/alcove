"""Explicit bundle placement and dependency plan for the pinned engine graph."""
import posixpath
from pathlib import PurePosixPath

FRAMEWORKS = {'JavaScriptCore.framework','WebCore.framework','WebGPU.framework',
              'WebInspectorUI.framework','WebKit.framework','WebKitLegacy.framework','_WebKit_SwiftUI.framework'}
SERVICES = {'com.apple.WebKit.'+name+'.xpc' for name in (
    'GPU','Model','Networking','WebContent','WebContent.CaptivePortal',
    'WebContent.Development','WebContent.EnhancedSecurity')}
LIBRARIES = {'libANGLE-shared.dylib','libWebKitSwift.dylib','libwebrtc.dylib'}
TOOLS = {'adattributiond','webpushd','webpushtool'}
METADATA = {'PAL.swiftmodule','WebKitSwift.swiftmodule','WebKitTestSupport',
            'libWebKitSwift.tbd','swift','usr'}
FRAMEWORK_DIRECTORY = 'Contents/Frameworks'
SERVICE_DIRECTORY = FRAMEWORK_DIRECTORY+'/WebKit.framework/Versions/A/XPCServices'


def require(value, message):
    if not value:
        raise ValueError(message)


def map_member(name):
    require(isinstance(name,str) and 0 < len(name) <= 4096 and '\\' not in name and '\0' not in name,
            'Invalid engine member')
    path = PurePosixPath(name)
    require(not path.is_absolute() and '..' not in path.parts and path.as_posix() == name and name != '.',
            'Unsafe or ambiguous engine member')
    top = path.parts[0]
    if top in FRAMEWORKS:
        return FRAMEWORK_DIRECTORY+'/'+name
    if top in LIBRARIES:
        require(len(path.parts) == 1, 'Unexpected member under engine library')
        return FRAMEWORK_DIRECTORY+'/'+name
    if top in SERVICES:
        return SERVICE_DIRECTORY+'/'+name
    if top in TOOLS:
        require(len(path.parts) == 1, 'Unexpected member under engine tool')
        return 'Contents/MacOS/'+name
    if top in METADATA:
        return 'Contents/Resources/EngineBuildMetadata/'+name
    if top in {'ANGLEMetalLib.metallib','AlcoveEngineBuild.json'}:
        require(len(path.parts) == 1, 'Unexpected member under engine resource')
        return 'Contents/Resources/AlcoveEngine/'+name
    raise ValueError('Unreviewed engine root: '+top)


def is_owned_reference(name):
    return any('/'+framework+'/' in name for framework in FRAMEWORKS) or PurePosixPath(name).name in LIBRARIES


def plan_relocations(images):
    require(len({image['path'] for image in images}) == len(images), 'Duplicate runtime image path')
    identities = {}
    for image in images:
        destination = map_member(image['path'])
        if image['identity'] is not None:
            require(destination.startswith(FRAMEWORK_DIRECTORY+'/'), 'Runtime library has no framework placement')
            require(image['identity'] not in identities, 'Duplicate runtime library identity')
            identities[image['identity']] = '@rpath/'+destination.removeprefix(FRAMEWORK_DIRECTORY+'/')
    result = {}
    for image in images:
        destination = map_member(image['path'])
        changes = {}
        for dependency in image['dependencies']:
            if dependency in identities:
                if identities[dependency] != dependency:
                    changes[dependency] = identities[dependency]
            elif is_owned_reference(dependency):
                raise ValueError('Unmapped owned framework dependency: '+dependency)
            else:
                require(dependency.startswith(('/System/Library/','/usr/lib/')),
                        'Unmapped runtime dependency: '+dependency)
        relative = posixpath.relpath(FRAMEWORK_DIRECTORY, str(PurePosixPath(destination).parent))
        rpath = '@loader_path' + ('/'+relative if relative != '.' else '')
        result[image['path']] = {
            'destination':destination,
            'identity':identities.get(image['identity']),
            'changes':changes,
            'removeRpaths':list(image['rpaths']),
            'addRpath':rpath,
        }
    return result
