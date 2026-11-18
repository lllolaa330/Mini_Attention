#!/usr/bin/env python3
"""Concurrency regression; run from project root with a NEW --outdir."""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from model import softfloat

WORKER = r'''
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from model import softfloat
if sys.argv[2] != '-':
    softfloat.ROOT = Path(sys.argv[2])
    softfloat.BUILD = softfloat.ROOT/'build'/'softfloat'
op=softfloat.ops()
for _ in range(10000):
    assert op['fma'](0x3c00,0x4000,0xbc00)==0x3c00
    assert op['fma'](1,0x3c00,0)==1
    assert op['div'](0x3c00,0x4000)==0x3800
print(json.dumps({'status':'PASS','checks':30000,'pid':__import__('os').getpid()}))
'''


def launch(commands, run, label, retained_ops=None):
    jobs=[]
    handles=[]
    start=time.monotonic()
    for i,command in enumerate(commands):
        log=(run/f'{label}_{i}.log').open('w')
        log.write('COMMAND: '+repr(command)+'\n');log.flush()
        handles.append(log)
        jobs.append(subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT))
    retained_checks=0
    try:
        while any(p.poll() is None for p in jobs):
            if time.monotonic()-start>120:
                raise TimeoutError(label)
            if retained_ops:
                for _ in range(100):
                    assert retained_ops['fma'](0x3c00,0x4000,0xbc00)==0x3c00
                    assert retained_ops['fma'](1,0x3c00,0)==1
                    assert retained_ops['div'](0x3c00,0x4000)==0x3800
                    retained_checks+=3
            time.sleep(0.001)
        codes=[p.wait() for p in jobs]
        assert codes==[0]*len(jobs), (label,codes)
        return {'status':'PASS','processes':len(jobs),'returncodes':codes,
                'retained_library_checks_during_rebuild':retained_checks,
                'elapsed_seconds':time.monotonic()-start}
    finally:
        for p in jobs:
            if p.poll() is None:p.kill();p.wait()
        for f in handles:f.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--outdir',type=Path,required=True)
    a=parser.parse_args()
    run=a.outdir.resolve();run.mkdir(parents=True,exist_ok=False)
    result={'status':'RUNNING','created_at':datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
            'command':sys.argv,'python':sys.version,'platform':platform.platform(),
            'softfloat_py_sha256':hashlib.sha256((ROOT/'model/softfloat.py').read_bytes()).hexdigest(),
            'cc':subprocess.run(['cc','--version'],capture_output=True,text=True).stdout}
    # Four independent processes cold-build the same initially absent project
    # cache; symlinks reuse only source, never the real project's build outputs.
    sandbox=Path(tempfile.mkdtemp(prefix='mini-attention-softfloat-concurrency-'))
    for directory in ('model','scripts','third_party'):(sandbox/directory).symlink_to(ROOT/directory,target_is_directory=True)
    result['fresh_workspace']=str(sandbox)
    try:
        result['cold_shared_build']=launch([[sys.executable,'-c',WORKER,str(ROOT),str(sandbox)] for _ in range(4)],run,'cold')
        shutil.copyfile(sandbox/'build/softfloat/build.log',run/'cold_build.log')
        # Hold a library handle in this process, then four normal model-unit-test
        # processes rebuild the same shared library while it remains callable.
        retained=softfloat.ops()
        lib=softfloat.BUILD/('libhalf.dylib' if sys.platform=='darwin' else 'libhalf.so')
        inode_before=lib.stat().st_ino
        result['warm_concurrent_model_tests']=launch([[sys.executable,'-m','unittest','discover','-s','tests','-v'] for _ in range(4)],run,'model',retained)
        inode_after=lib.stat().st_ino
        result['warm_concurrent_model_tests'].update(inode_before=inode_before,inode_after=inode_after)
        assert inode_before!=inode_after, 'Library should be replaced rather than overwritten'
        assert retained['fma'](0x3c00,0x4000,0xbc00)==0x3c00
        assert result['warm_concurrent_model_tests']['retained_library_checks_during_rebuild']>0
        result['temporary_libraries_left']=list(map(str,softfloat.BUILD.glob('.libhalf-*')))
        assert not result['temporary_libraries_left']
        shutil.copyfile(softfloat.BUILD/'build.log',run/'warm_build.log')
        result['status']='PASS'
    except Exception as e:
        result.update(status='FAIL',error=repr(e));raise
    finally:
        (run/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
