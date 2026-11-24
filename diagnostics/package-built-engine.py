#!/usr/bin/env python3
"""Package only reviewed runtime products from a fresh native source build."""
import argparse,hashlib,importlib.util,io,json,os,re,tarfile,tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('jsc_runtime_archive',Path(__file__).with_name('prepare-jsc-runtime.py'))
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
u=runtime.archive_utils;require=u.require
MAIN={'JavaScriptCore.framework':'JavaScriptCore','WebCore.framework':'WebCore','WebKit.framework':'WebKit'}
def run(product,contract_path,manifest_path,output):
    c=u.load_json(contract_path);m=u.load_json(manifest_path)
    require(isinstance(c,dict) and set(c)=={'formatVersion','webkitRevision','runtimeRoots','patches'} and c['formatVersion']==1,'Invalid runtime root contract')
    require(isinstance(c['webkitRevision'],str) and re.fullmatch('[0-9a-f]{40}',c['webkitRevision']),'Invalid source revision')
    roots=c['runtimeRoots'];require(isinstance(roots,list) and 0<len(roots)<=64 and len(roots)==len(set(roots)),'Invalid runtime roots')
    require(all(isinstance(n,str) and u.relative_name(n)==n and '/' not in n and n!='.' for n in roots) and set(MAIN)<=set(roots),'Unreviewed runtime roots')
    patches=c['patches'];require(isinstance(patches,dict) and 0<len(patches)<=100,'Missing source patch contract')
    require(all(isinstance(n,str) and re.fullmatch('[A-Za-z0-9_.-]+\\.patch',n) and isinstance(d,str) and re.fullmatch('[0-9a-f]{64}',d) for n,d in patches.items()),'Invalid patch contract')
    require(isinstance(m,dict) and m.get('formatVersion')==1 and m.get('webkitRevision')==c['webkitRevision'] and m.get('patches')==patches,'Build source manifest differs')
    require(isinstance(m.get('wrapperCommit'),str) and re.fullmatch('[0-9a-f]{40}',m['wrapperCommit']),'Missing wrapper source')
    require(m.get('sdk')=='26.5' and m.get('emptyProductsAtStart') is True,'Unexpected toolchain or reused native products')
    require(isinstance(m.get('buildCommand'),list) and m['buildCommand'] and all(isinstance(n,str) and 0<len(n)<=4096 for n in m['buildCommand']),'Missing build command')
    require(product.is_dir() and not product.is_symlink(),'Missing native product directory')
    require(not output.exists() and not output.is_symlink(),'Archive output already exists')
    require(not output.resolve().is_relative_to(product.resolve()),'Archive output must be outside native products')
    framework_digests={}
    for framework,name in MAIN.items():
        binary=product/framework/'Versions/A'/name
        require(binary.resolve(strict=True).is_relative_to(product.resolve()) and binary.is_file() and not binary.is_symlink() and binary.stat().st_size>0 and binary.stat().st_mode&0o100,'Missing rebuilt executable: '+framework)
        framework_digests[framework]=u.digest_file(binary)
    require(all((product/name).exists() for name in roots),'Missing approved runtime product')
    record=json.dumps({'formatVersion':1,'source':m,'frameworkSHA256':framework_digests},sort_keys=True,indent=2).encode()+b'\n'
    output.parent.mkdir(parents=True,exist_ok=True)
    descriptor,raw=tempfile.mkstemp(prefix='.alcove-engine-package-',suffix='.tar.gz',dir=output.parent);os.close(descriptor);stage=Path(raw)
    try:
        def keep(info):
            return None if any(part.endswith(('.dSYM','.a','.o')) for part in Path(info.name).parts) else info
        with tarfile.open(stage,'w:gz',dereference=False) as archive:
            for name in sorted(roots):archive.add(product/name,arcname=name,filter=keep)
            info=tarfile.TarInfo('AlcoveEngineBuild.json');info.size=len(record);info.mode=0o644;archive.addfile(info,io.BytesIO(record))
        with tarfile.open(stage,'r:gz') as archive:
            members=u.validate_members(archive,exclude_member=lambda _:False,validate_link=runtime.validate_runtime_link)
        require({n.split('/')[0] for n in members}==set(roots)|{'AlcoveEngineBuild.json'},'Packaged runtime root inventory differs')
        runtime.verify_links(product,members,allowed_roots=set(roots))
        for name,member in members.items():
            if member.issym():
                path=(product/name).resolve(strict=False)
                target=path.relative_to(product.resolve()).as_posix()
                # Xcode emits this standard WebCore bundle link even when the
                # build has no embedded frameworks. Preserve its exact layout;
                # every other link still needs its actual packaged target.
                optional=(name=='WebCore.framework/Frameworks' and
                          member.linkname=='Versions/Current/Frameworks' and
                          target=='WebCore.framework/Versions/A/Frameworks' and
                          not path.exists())
                require(optional or (path.exists() and target in members),'Runtime link targets an omitted product')
        require(not output.exists() and not output.is_symlink(),'Archive output already exists')
        os.rename(stage,output)
    finally:
        if stage.exists():stage.unlink()
    print('FRESH_SOURCE_ENGINE_PACKAGED',len(roots),len(members),json.dumps(framework_digests,sort_keys=True))
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['product','contract','manifest','output']:parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();run(args.product,args.contract,args.manifest,args.output)
