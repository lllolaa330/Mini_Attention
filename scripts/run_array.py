#!/usr/bin/env python3
"""Check array timing and FP16 results against sequential SoftFloat FMA."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import struct
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from model.softfloat import ops
from scripts.run import command, compile_tb, write_json


def encode(x):
    return struct.unpack('>H',struct.pack('>e',x))[0]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sim',choices=['iverilog','verilator'],default='iverilog')
    p.add_argument('--dataflow', choices=['os', 'ws'], default='os')
    p.add_argument('--size',type=int,default=16,choices=[2,16])
    p.add_argument('--outdir',type=Path)
    p.add_argument('--seed',type=int,default=20261117)
    p.add_argument('--timeout',type=int,default=600)
    args=p.parse_args(); args.waves=False
    now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    stamp=now.strftime('%Y%m%d_%H%M%S')
    name = f'array{args.size}' if args.dataflow == 'os' else f'array_ws{args.size}'
    run=(args.outdir or ROOT/'results'/f'{name}_{stamp}_{args.sim}').resolve()
    run.mkdir(parents=True,exist_ok=False)
    n = args.size
    k = n if args.dataflow == 'ws' else 16
    rng=random.Random(args.seed)
    fma=ops()['fma']
    matrices=[]
    matrices.append(([0]*(n*k),[0]*(k*n)))
    matrices.append(([0x4000]*(n*k),[0xc000]*(k*n)))
    matrices.append(([0x8000]*(n*k),[0x3c00]*(k*n)))
    matrices.append(([0x3c00 if i==t else 0 for i in range(n) for t in range(k)],
                     [encode((t-j)/8) for t in range(k) for j in range(n)]))
    matrices.append(([0x0001 if (i+t)%2 else 0x8001 for i in range(n) for t in range(k)],
                     [0x4000 if t%2 else 0xc000 for t in range(k) for j in range(n)]))
    for mode in range(3):
        def value():
            if mode==0: return encode(rng.uniform(-2,2))
            if mode==1: return rng.randrange(0x4001) | (rng.randrange(2)<<15)
            return rng.choice([0x3fff,0x4000,0xbfff,0xc000,0x0400,0x03ff,0x8001])
        matrices.append(([value() for _ in range(n*k)],[value() for _ in range(k*n)]))
    avec=[]; bvec=[]; evec=[]
    for a,b in matrices:
        avec.extend(a); bvec.extend(b)
        for i in range(n):
            for j in range(n):
                acc=0
                for t in range(k): acc=fma(a[i*k+t],b[t*n+j],acc)
                evec.append(acc)
    for filename,words in [('a.hex',avec),('b.hex',bvec),('expected.hex',evec)]:
        (run/filename).write_text(''.join(f'{w:04x}\n' for w in words))
    manifest={'status':'RUNNING','created_at':now.isoformat(),'seed':args.seed,'array_size':n,'dot_length':k,
              'frames':len(matrices),'outputs':len(evec),'commands':sys.argv,
              'dataflow': args.dataflow, 'simulator': args.sim,
              'logical_steps_per_gemm':3*n-1 if args.dataflow == 'ws' else k+2*(n-1),
              'weight_load_cycles_per_gemm': n if args.dataflow == 'ws' else 0, 'sources_sha256':{}}
    for base in ('rtl','tb','model','scripts','third_party/HardFloat-1','third_party/softfloat_source'):
        for path in sorted((ROOT/base).rglob('*')):
            if path.is_file() and path.suffix in ('.sv','.v','.vi','.c','.h','.py','.f'):
                manifest['sources_sha256'][str(path.relative_to(ROOT))]=hashlib.sha256(path.read_bytes()).hexdigest()
    write_json(run/'manifest.json',manifest)
    try:
        command([args.sim,'--version'] if args.sim=='verilator' else ['iverilog','-V'],run/'tool_version.log',60)
        bench = 'tb_array_ws' if args.dataflow == 'ws' else 'tb_array'
        exe=compile_tb(args,run,bench,'N',n)
        command(exe+['+A=a.hex','+B=b.hex','+EXPECTED=expected.hex',f'+COUNT={len(matrices)}'],
                run/'array.log',args.timeout,cwd=run)
        if 'PASS array' not in (run/'array.log').read_text(): raise RuntimeError('Array PASS missing')
        manifest['status']='PASS'
        print(f'ARRAY PASS: {n}x{n}, {len(evec)} outputs; {run}')
    except Exception as e:
        manifest.update(status='FAIL',error=repr(e)); raise
    finally: write_json(run/'manifest.json',manifest)


if __name__=='__main__': main()
