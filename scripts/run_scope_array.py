#!/usr/bin/env python3
"""Exercise one- and two-strip SCOPE arrays, including concurrent preload and holds."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import encode
from model.scope_attention import bit_model_with_probabilities, dot16, scna_exp16
from model.softfloat import ops


def run(command, cwd, log):
    with log.open('w') as f:
        print('COMMAND:', repr(command), file=f, flush=True)
        subprocess.run(command, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=int, default=20261118)
    parser.add_argument('--outdir', type=Path)
    args = parser.parse_args()
    if args.outdir:
        dest = args.outdir.resolve()
        dest.mkdir(parents=True, exist_ok=False)
    else:
        stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        dest = Path(tempfile.mkdtemp(prefix=f'scope_array_{stamp}_', dir=ROOT/'results'))

    rtl = [f'rtl/scope_{name}.sv' for name in ('standard_pe', 'left_pe', 'right_pe', 'array')]
    bench = 'tb/tb_scope_array.sv'
    lint_flags = ['verilator', '--lint-only', '--Wall', '--top-module', 'scope_array',
                  'scripts/verilator_lint.vlt', '-f', 'rtl/files.f', *rtl]
    deps = [*rtl, bench, 'rtl/scope_exp_coeffs.svh', 'rtl/fp16_ops.sv', 'rtl/files.f',
            'model/scope_attention.py', 'scripts/run_scope_array.py']
    manifest = {'status': 'RUNNING', 'seed': args.seed, 'command': sys.argv,
                'sources_sha256': {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in deps},
                'iverilog': subprocess.check_output(['iverilog', '-V'], stderr=subprocess.STDOUT,
                                                     text=True).splitlines()[0],
                'verilator': subprocess.check_output(['verilator', '--version'], text=True).strip()}

    try:
        rng = random.Random(args.seed)
        op = ops()
        q, k, v = [[encode(rng.uniform(-2, 2)) for _ in range(256)] for _ in range(3)]
        y, p = bit_model_with_probabilities(q+k+v)
        qk = [dot16(q[i:i+16], k[j:j+16], op['fma']) for i in range(0,256,16)
              for j in range(0,256,16)]
        x = [encode(rng.uniform(-12, 0)) for _ in range(256)]
        x[:6] = [0, 0x8000, 0x8001, encode(-32), encode(-2), encode(-1)]
        exp = [scna_exp16(value, op) for value in x]
        for name, words in [('q',q), ('k',k), ('v',v), ('p',p), ('qk',qk), ('y',y), ('x',x), ('exp',exp)]:
            (dest/(name+'.hex')).write_text(''.join(f'{h:04x}\n' for h in words))

        for strips in [1, 2]:
            run([*lint_flags, f'-GSTRIPS={strips}'], ROOT, dest/f'lint_{strips}.log')
            exe = dest/f'array_{strips}.vvp'
            run(['iverilog', '-g2012','-s','tb_scope_array',f'-Ptb_scope_array.STRIPS={strips}',
                 '-o', str(exe), '-f', 'rtl/files.f', *rtl, bench], ROOT, dest/f'compile_{strips}.log')
            log = dest/f'sim_{strips}.log'
            run(['vvp',str(exe)],dest,log)
            if f'PASS STRIPS={strips} raw_QK=256 Exp=256 PV=256' not in log.read_text():
                raise RuntimeError(f'Missing self-check result: {log}')
        manifest['status'] = 'PASS'
        print(f'SCOPE ARRAY PASS: {dest}')
    except Exception as error:
        manifest.update(status='FAIL', error=repr(error))
        print(f'Evidence: {dest}', file=sys.stderr)
        raise
    finally:
        (dest/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')


if __name__ == '__main__':
    main()
