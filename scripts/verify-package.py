"""Verify the delivered app structure, permissions and declared version in the ZIP."""
import plistlib
import sys
import zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    assert all('..' not in PurePosixPath(name).parts and not name.startswith('/') for name in names)
    assert 'Alcove.app/Contents/Resources/Alcove.icns' in names
    assert 'Alcove.app/Contents/Resources/LICENSE.txt' in names, 'Redistributed app must include its license'
    info = plistlib.loads(archive.read('Alcove.app/Contents/Info.plist'))
    executable = 'Alcove.app/Contents/MacOS/' + info['CFBundleExecutable']
    assert archive.getinfo(executable).external_attr >> 16 & 0o111, 'App executable lost its executable bit'
    assert info['CFBundleName'] == 'Alcove'
    assert info['LSMinimumSystemVersion'] == '14.0'
    assert not any(name.endswith(('.sealed', 'session.json', '.key', '.p12')) for name in names)
    print('PASS: ZIP contains an executable Alcove app, icon and macOS version metadata, without local sessions or keys')
