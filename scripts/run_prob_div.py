#!/usr/bin/env python3
"""Check both pipeline stages and binary16 rounding against Berkeley SoftFloat."""
import argparse
from collections import Counter
from datetime import datetime
from hashlib import sha256
from pathlib import Path
import random
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.softfloat import ops
from scripts.run import command, write_json


def inputs(seed):
    # Sweep every legal magnitude along either axis, then vary both together.
    for a in range(0x3c01):
        for b in (0x3c00, 0x3c01, 0x3e00, 0x4000, 0x4bff, 0x4c00):
            yield a, b
    for b in range(0x3c00, 0x4c01):
        for a in (1, 3, 0x03ff, 0x0400, 0x07ff, 0x0800, 0x3bff, 0x3c00):
            yield a, b
    rng = random.Random(seed)
    for _ in range(20000):
        yield rng.randrange(0x3c01), rng.randrange(0x3c00, 0x4c01)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--outdir', type=Path)
    parser.add_argument('--seed', type=int, default=20261118)
    args = parser.parse_args()
    stamp = datetime.now().astimezone().strftime('%Y%m%d_%H%M%S')
    dest = (args.outdir or ROOT/'results'/f'prob_div_{stamp}').resolve()
    dest.mkdir(parents=True, exist_ok=False)
    coverage = Counter()
    divide = ops()['div']
    paths = ['rtl/fp16_prob_div.sv', 'tb/tb_prob_div.sv', 'scripts/run_prob_div.py',
             'model/softfloat.py', 'model/softfloat_bridge.c']
    manifest = {
        'status': 'RUNNING', 'tool': subprocess.check_output(['iverilog', '-V'], stderr=subprocess.DEVNULL,
                                                             text=True).splitlines()[0],
        'python': sys.version, 'seed': args.seed, 'command': sys.argv,
        'sources_sha256': {f: sha256((ROOT/f).read_bytes()).hexdigest() for f in paths},
    }
    try:
        with (dest/'vectors.hex').open('w') as stream:
            for a, b in inputs(args.seed):
                y = divide(a, b)
                stream.write(f'{a:04x}{b:04x}{y:04x}\n')
                coverage['total'] += 1
                if y == 0 and a: coverage['underflow_to_zero'] += 1
                if 0 < y < 0x400: coverage['subnormal_results'] += 1
                if y == 0x400: coverage['smallest_normal_results'] += 1
                # Exact halfway in the subnormal region when dividing an odd
                # integer multiple of 2^-24 by 2. Exercise ties of both parities.
                if b == 0x4000 and 0 < a < 0x0400 and a % 2:
                    coverage['halfway_up' if a%4 == 3 else 'halfway_down'] += 1
        required = ('underflow_to_zero','subnormal_results','smallest_normal_results','halfway_up','halfway_down')
        if not all(coverage[key] for key in required):
            raise ValueError(f'Missing coverage: {coverage}')
        command(['iverilog','-g2012','-Wall','-s','tb_prob_div','-o',dest/'test.vvp',*paths[:2]],
                dest/'compile.log')
        command(['vvp',dest/'test.vvp',f"+COUNT={coverage['total']}"],dest/'simulation.log',cwd=dest)
        if 'PROB DIV PASS' not in (dest/'simulation.log').read_text(): raise RuntimeError('Missing pass')
        manifest.update(status='PASS', coverage=dict(coverage))
        print('Evidence:',dest)
    finally:
        if manifest['status'] != 'PASS':
            manifest['status'] = 'FAIL'
        write_json(dest/'manifest.json', manifest)


if __name__ == '__main__':
    main()
