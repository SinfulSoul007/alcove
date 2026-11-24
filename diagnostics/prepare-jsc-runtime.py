#!/usr/bin/env python3
"""Compose a rebuilt JavaScriptCore with an exact, unchanged WebKit runtime."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import tarfile
import tempfile
import zipfile

spec=importlib.util.spec_from_file_location('alcove_dependency_archive',Path(__file__).with_name('prepare-webkit-dependencies.py'))
archive_utils=importlib.util.module_from_spec(spec);spec.loader.exec_module(archive_utils)
require=archive_utils.require
JSC='JavaScriptCore.framework/Versions/A/JavaScriptCore'
RECEIPT='AlcoveJavaScriptCoreBaseline.json'
VERIFIED='AlcoveJavaScriptCoreVerification.json'

def omitted(name):
    top=name.split('/',1)[0]
    return top in {'JavaScriptCore.framework','DerivedSources'} or top.startswith('._')

def validate_runtime_link(name,target):
    require(isinstance(target,str) and 0<len(target)<=2048 and "\\" not in target and "\0" not in target,'Invalid runtime link')
    require(not PurePosixPath(target).is_absolute(),'Absolute runtime link')
    combined=posixpath.normpath(str(PurePosixPath(name).parent/target))
    require(archive_utils.relative_name(combined)==combined and combined!='.','Runtime link escapes root')

def verify_links(root,members):
    resolved=root.resolve(strict=True)
    for name,member in members.items():
        if member.issym():
            require((root/name).resolve(strict=False).is_relative_to(resolved),'Runtime link chain escapes root')

def load_contract(path):
    c=archive_utils.load_json(path)
    fields={'formatVersion','artifactID','archiveSHA256','runtimeSHA256','wrapperCommit','webkitRevision','patches','additionalPatch','retainedRoots','retainedBinaries','oldJavaScriptCoreSHA256'}
    require(isinstance(c,dict) and set(c)==fields and c['formatVersion']==1,'Invalid JSC baseline contract')
    require(type(c['artifactID']) is int and c['artifactID']>0,'Invalid artifact ID')
    for key in ['wrapperCommit','webkitRevision']:
        require(isinstance(c[key],str) and re.fullmatch('[0-9a-f]{40}',c[key]),'Invalid source revision')
    for key in ['archiveSHA256','runtimeSHA256','oldJavaScriptCoreSHA256']:
        require(isinstance(c[key],str) and re.fullmatch('[0-9a-f]{64}',c[key]),'Invalid baseline digest')
    roots=c['retainedRoots'];require(isinstance(roots,list) and 0<len(roots)<=64 and len(set(roots))==len(roots),'Invalid retained roots')
    require(all(isinstance(n,str) and archive_utils.relative_name(n)==n and '/' not in n and n!='.' and not omitted(n) for n in roots),'Unsafe retained root')
    binaries=c['retainedBinaries'];require(isinstance(binaries,dict) and 0<len(binaries)<=64,'Missing retained binaries')
    for name,digest in binaries.items():
        require(archive_utils.relative_name(name)==name and name.split('/',1)[0] in roots,'Unreviewed retained binary')
        require(isinstance(digest,str) and re.fullmatch('[0-9a-f]{64}',digest),'Invalid binary digest')
    additional=c['additionalPatch'];patches=c['patches']
    require(isinstance(additional,dict) and set(additional)=={'name','sha256','paths'},'Invalid new patch')
    require(additional['paths']==['Source/JavaScriptCore/runtime/JSGlobalObject.cpp'],'New patch must stay in the reviewed scheduler source')
    require(isinstance(patches,dict) and 0<len(patches)<=100 and additional['name'] not in patches,'Invalid baseline patches')
    for name,digest in list(patches.items())+[(additional['name'],additional['sha256'])]:
        require(isinstance(name,str) and re.fullmatch('[A-Za-z0-9_.-]+\\.patch',name),'Invalid patch name')
        require(isinstance(digest,str) and re.fullmatch('[0-9a-f]{64}',digest),'Invalid patch digest')
    return c

def verify_retained(root,c):
    resolved=root.resolve(strict=True)
    for name,digest in c['retainedBinaries'].items():
        path=root/name
        require(path.resolve(strict=True).is_relative_to(resolved),'Retained binary escaped runtime')
        require(archive_utils.digest_file(path)==digest,'Retained binary changed: '+name)

def prepare(archive,destination,patches,c):
    require(not destination.exists() and not destination.is_symlink(),'Destination already exists')
    archive_utils.verify_patches(patches,c)
    require(archive_utils.digest_file(archive)==c['archiveSHA256'],'Artifact digest differs')
    stage=None
    try:
        with zipfile.ZipFile(archive) as package,tempfile.TemporaryFile() as runtime:
            names=package.namelist();require(len(names)==len(archive_utils.ZIP_NAMES) and set(names)==archive_utils.ZIP_NAMES,'Unexpected or duplicate artifact entries')
            for info in package.infolist():
                limit=256*1024*1024 if info.filename=='Alcove-WebKitRuntime.tar.gz' else 65536
                require(info.file_size<=limit,'Artifact entry too large')
            require(package.read('AlcoveSource.txt')==(c['wrapperCommit']+'\n').encode(),'Baseline wrapper source differs')
            require(package.read('WebKitSource.txt')==(c['webkitRevision']+'\n').encode(),'Baseline WebKit source differs')
            rows=package.read('PatchChecksums.txt').decode().splitlines()
            parsed=[re.fullmatch(r'([0-9a-f]{64})  diagnostics/([A-Za-z0-9_.-]+\.patch)',row) for row in rows]
            require(all(parsed),'Invalid baseline patch metadata')
            require(len(rows)==len(c['patches']) and {m[2]:m[1] for m in parsed}==c['patches'],'Baseline patches differ')
            require(package.read('SHA256SUMS.txt')==(c['runtimeSHA256']+'  Alcove-WebKitRuntime.tar.gz\n').encode(),'Runtime checksum metadata differs')
            digest=hashlib.sha256()
            with package.open('Alcove-WebKitRuntime.tar.gz') as source:
                while chunk:=source.read(1024*1024):digest.update(chunk);runtime.write(chunk)
            require(digest.hexdigest()==c['runtimeSHA256'],'Runtime digest differs');runtime.seek(0)
            with tarfile.open(fileobj=runtime,mode='r:gz') as tar:
                members=archive_utils.validate_members(tar,exclude_member=omitted,validate_link=validate_runtime_link)
                require(all(n.split('/',1)[0] in c['retainedRoots'] for n in members),'Unreviewed runtime root')
                old=next((m for m in tar.getmembers() if archive_utils.relative_name(m.name)==JSC),None)
                require(old is not None and old.isfile(),'Baseline JSC missing')
                with tar.extractfile(old) as binary:
                    old_digest=hashlib.sha256()
                    while chunk:=binary.read(1024*1024):old_digest.update(chunk)
                    require(old_digest.hexdigest()==c['oldJavaScriptCoreSHA256'],'Baseline JSC differs')
                destination.parent.mkdir(parents=True,exist_ok=True)
                stage=Path(tempfile.mkdtemp(prefix='.alcove-jsc-runtime-',dir=destination.parent))
                archive_utils.extract_dependencies(tar,members,stage)
                verify_links(stage,members)
            verify_retained(stage,c)
            require(not (stage/'JavaScriptCore.framework').exists() and not (stage/'DerivedSources').exists(),'Stale JSC products imported')
            (stage/RECEIPT).write_text(json.dumps({'formatVersion':1,'contract':c},indent=2,sort_keys=True)+'\n')
            require(not destination.exists() and not destination.is_symlink(),'Destination already exists')
            os.rename(stage,destination);stage=None
    finally:
        if stage is not None:shutil.rmtree(stage)
    print('VERIFIED_JSC_BASELINE_PREPARED',len(c['retainedBinaries']))

def verify(destination,c):
    require(archive_utils.load_json(destination/RECEIPT)=={'formatVersion':1,'contract':c},'JSC baseline receipt differs')
    verify_retained(destination,c)
    path=destination/JSC;require(path.resolve(strict=True).is_relative_to(destination.resolve(strict=True)),'Rebuilt JSC escaped runtime')
    require(path.is_file() and not path.is_symlink() and path.stat().st_size>0,'Rebuilt JSC missing')
    current=archive_utils.digest_file(path);require(current!=c['oldJavaScriptCoreSHA256'],'Baseline JSC was not rebuilt')
    (destination/VERIFIED).write_text(json.dumps({'formatVersion':1,'baselineWrapper':c['wrapperCommit'],'newJavaScriptCoreSHA256':current,'unchangedRetainedBinaries':len(c['retainedBinaries']),'additionalPatch':c['additionalPatch']},indent=2,sort_keys=True)+'\n')
    print('REBUILT_JSC_AND_UNCHANGED_RUNTIME_VERIFIED',current,len(c['retainedBinaries']))

def main():
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='command',required=True)
    for name in ['prepare','verify']:
        command=commands.add_parser(name);command.add_argument('--destination',type=Path,required=True)
        command.add_argument('--contract',type=Path,default=Path(__file__).with_name('jsc-runtime-baseline.json'))
        if name=='prepare':command.add_argument('--archive',type=Path,required=True);command.add_argument('--patch-directory',type=Path,required=True)
    args=parser.parse_args()
    try:
        c=load_contract(args.contract)
        if args.command=='prepare':prepare(args.archive,args.destination,args.patch_directory,c)
        else:verify(args.destination,c)
    except (ValueError,OSError,RuntimeError,tarfile.TarError,zipfile.BadZipFile) as error:parser.exit(1,'JSC runtime verification failed: '+str(error)+'\n')
if __name__=='__main__':main()
