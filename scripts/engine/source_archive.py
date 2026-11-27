"""Archive raw Git blobs without export filters, EOL conversion or substitutions."""
import gzip
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

from source_notices import source_tree
from verified_input import PIN, require


def create_source_archive(repository, revision, destination):
    require(not destination.exists() and not destination.is_symlink(), 'Source archive destination already exists')
    require(not destination.resolve().is_relative_to(repository.resolve()), 'Source archive destination is inside Git input')
    entries = source_tree(repository, revision)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.alcove-source-archive-', dir=destination.parent) as temporary:
        stage = Path(temporary)/'source.tar.gz'
        with (Path(temporary)/'git-errors').open('w+b') as errors:
            process = subprocess.Popen(['git', '-C', str(repository), 'cat-file', '--batch'],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            try:
                with stage.open('xb') as output, gzip.GzipFile(filename='', mode='wb',
                        fileobj=output, mtime=0, compresslevel=1) as compressed:
                    with tarfile.open(mode='w|', fileobj=compressed, format=tarfile.PAX_FORMAT) as archive:
                        for name, (mode, oid) in sorted(entries.items()):
                            process.stdin.write(oid.encode('ascii')+b'\n'); process.stdin.flush()
                            header = process.stdout.readline(256).split()
                            require(len(header) == 3 and header[0].decode('ascii') == oid and
                                    header[1] == b'blob' and header[2].isdigit(), 'Git source blob is unavailable')
                            size = int(header[2])
                            require(0 <= size <= 512*1024*1024, 'Oversized Git source blob')
                            item = tarfile.TarInfo('WebKit-'+revision+'/'+name)
                            item.uid = item.gid = item.mtime = 0
                            if mode == '120000':
                                require(size <= 4096, 'Oversized source link')
                                target = process.stdout.read(size)
                                require(len(target) == size, 'Truncated Git source link')
                                item.type = tarfile.SYMTYPE; item.mode = 0o777
                                item.linkname = target.decode('utf-8')
                                archive.addfile(item)
                            else:
                                item.mode = 0o755 if mode == '100755' else 0o644
                                item.size = size
                                archive.addfile(item, process.stdout)
                            require(process.stdout.read(1) == b'\n', 'Git source blob framing differs')
                process.stdin.close()
                require(process.wait(timeout=120) == 0, 'Git source archive reader failed')
                os.link(stage, destination)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                process.stdout.close()
                if not process.stdin.closed: process.stdin.close()
    return {'revision': revision, 'sourceMembers': len(entries), 'archive': str(destination)}


if __name__ == '__main__':
    import argparse
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-git', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = create_source_archive(args.source_git, PIN['webkitRevision'], args.destination)
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error)+'\n')
    print(json.dumps(result))
