#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.gen_arithmetic import vectors
from scripts.run import command, compile_tb, write_json


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--sim', choices=['iverilog','verilator'], default='iverilog')
    p.add_argument('--outdir', type=Path)
    p.add_argument('--seed', type=int, default=20261117)
    p.add_argument('--random', type=int, default=3000)
    p.add_argument('--timeout', type=int, default=600)
    args=p.parse_args()
    args.waves=False
    stamp=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime('%Y%m%d_%H%M%S')
    run=(args.outdir or ROOT/'results'/f'arithmetic_{stamp}_{args.sim}').resolve()
    run.mkdir(parents=True,exist_ok=False)
    words=vectors(args.seed,args.random)
    (run/'arithmetic.hex').write_text(''.join(f'{v:017x}\n' for v in words))
    manifest={'status':'RUNNING','seed':args.seed,'random_per_op':args.random,'cases':len(words),
              'commands':sys.argv,'sources_sha256':{}}
    for base in ('rtl','tb','model','scripts','third_party/HardFloat-1','third_party/softfloat_source'):
        for path in sorted((ROOT/base).rglob('*')):
            if path.is_file() and path.suffix in ('.sv','.v','.vh','.c','.h','.py','.f'):
                manifest['sources_sha256'][str(path.relative_to(ROOT))]=hashlib.sha256(path.read_bytes()).hexdigest()
    write_json(run/'manifest.json',manifest)
    try:
        exe=compile_tb(args,run,'tb_fp16',None,len(words))
        command(exe+['+VECTORS=arithmetic.hex',f'+COUNT={len(words)}'],run/'arithmetic.log',args.timeout,cwd=run)
        if 'ARITHMETIC PASS' not in (run/'arithmetic.log').read_text():
            raise RuntimeError('Arithmetic PASS missing')
        manifest['status']='PASS'
        print(f'ARITHMETIC PASS: {len(words)} vectors; {run}')
    except Exception as e:
        manifest.update(status='FAIL',error=repr(e))
        raise
    finally:
        write_json(run/'manifest.json',manifest)


if __name__ == '__main__': main()
