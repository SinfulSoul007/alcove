"""Verify the delivered app structure, permissions and declared version in the ZIP."""
import plistlib
import sys
import zipfile
from pathlib import PurePosixPath
from website_protection import LIMITS, validate_catalog
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    assert all('..' not in PurePosixPath(name).parts and not name.startswith('/') for name in names)
    assert 'Alcove.app/Contents/Resources/Alcove.icns' in names
    assert 'Alcove.app/Contents/Resources/LICENSE.txt' in names, 'Redistributed app must include its license'
    resources = {}
    for name, limit in LIMITS.items():
        resource = 'Alcove.app/Contents/Resources/WebsiteProtection/' + name
        assert names.count(resource) == 1, 'Missing or ambiguous website protection resource: ' + name
        assert archive.getinfo(resource).file_size <= limit, 'Oversized website protection resource: ' + name
        resources[name] = archive.read(resource)
    catalog = validate_catalog(resources['domains.txt'], resources['source.json'], resources['LICENSE.PhishDestroy.txt'])
    info = plistlib.loads(archive.read('Alcove.app/Contents/Info.plist'))
    executable = 'Alcove.app/Contents/MacOS/' + info['CFBundleExecutable']
    assert archive.getinfo(executable).external_attr >> 16 & 0o111, 'App executable lost its executable bit'
    assert info['CFBundleName'] == 'Alcove'
    assert info['LSMinimumSystemVersion'] == '14.0'
    assert any(
        declaration.get('UTTypeIdentifier') == 'dev.openbrowser.mac.sidebar-tab'
        and 'public.data' in declaration.get('UTTypeConformsTo', [])
        for declaration in info.get('UTExportedTypeDeclarations', [])
    ), 'macOS requires a bundle declaration for the sidebar tab drag type'
    assert not any(name.endswith(('.sealed', 'session.json', '.key', '.p12')) for name in names)
    print('PASS: ZIP contains an executable Alcove app, icon and macOS version metadata, without local sessions or keys')
    print('PASS: ZIP includes the verified phishing catalog and publisher license;', catalog['domainCount'], 'domains')
