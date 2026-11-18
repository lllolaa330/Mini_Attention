#!/usr/bin/env python3
"""Strict RTL lint, with narrow documented waivers and unfiltered audit log."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--outdir',type=Path)
    p.add_argument('--dataflow',choices=['os','ws'],default='os')
    args=p.parse_args()
    now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    run=(args.outdir or ROOT/'results'/('lint_'+args.dataflow+'_'+now.strftime('%Y%m%d_%H%M%S'))).resolve()
    run.mkdir(parents=True,exist_ok=False)
    use_ws = int(args.dataflow == 'ws')
    cmd=['verilator','--lint-only','--Wall','--top-module','attention_fp16',f"-GUSE_WS=1'b{use_ws}"]
    manifest={'status':'RUNNING','created_at':now.isoformat(),'dataflow':args.dataflow,
              'use_ws':use_ws,'sources_sha256':{}}
    for base in ('rtl','third_party/HardFloat-1','scripts'):
        for path in sorted((ROOT/base).rglob('*')):
            if path.is_file() and path.suffix in ('.sv','.v','.vi','.f','.vlt','.py'):
                manifest['sources_sha256'][str(path.relative_to(ROOT))]=hashlib.sha256(path.read_bytes()).hexdigest()
    def execute(argv,name):
        with (run/name).open('w') as log:
            log.write('COMMAND: '+repr(argv)+'\n'); log.flush()
            return subprocess.run(argv,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT).returncode
    try:
        execute(['verilator','--version'],'tool_version.log')
        raw=execute(cmd+['-Wno-fatal','-f','rtl/files.f'],'unfiltered.log')
        rc=execute(cmd+['scripts/verilator_lint.vlt','-f','rtl/files.f'],'strict.log')
        manifest.update(unfiltered_exit=raw,strict_exit=rc,status='PASS' if rc==0 else 'FAIL')
        if rc:
            print((run/'strict.log').read_text(),file=sys.stderr)
            raise RuntimeError('Strict lint failed')
        print('LINT PASS:',run)
    finally:
        (run/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


if __name__=='__main__': main()
