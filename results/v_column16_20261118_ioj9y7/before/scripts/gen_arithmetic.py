#!/usr/bin/env python3
"""Independent SoftFloat vectors: 68 bits op/a/b/c/expected."""
import argparse
from pathlib import Path
import random
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.softfloat import ops


def vectors(seed=20261117, count=3000):
    op = ops()
    rng = random.Random(seed)
    boundaries = [0, 0x8000, 1, 0x8001, 0x3ff, 0x83ff, 0x400, 0x8400,
                  0x3c00, 0xbc00, 0x4000, 0xc000, 0x3bff, 0xbbff,
                  0x7bff, 0xfbff, 0x1000, 0x9000, 0x7c00, 0xfc00]
    values = []
    for code, name in enumerate(('fma','add','sub','mul','div')):
        for a in boundaries:
            for b in boundaries:
                c = rng.choice(boundaries)
                y = op[name](a, b, c) if code == 0 else op[name](a,b)
                # IEEE allows different NaN payloads; these compare canonical
                # output below in TB. Legal attention never enters NaN paths.
                values.append((code << 64) | (a << 48) | (b << 32) | (c << 16) | y)
        for _ in range(count):
            a,b,c = [rng.randrange(0x7c00) | (rng.randrange(2)<<15) for _ in range(3)]
            y = op[name](a,b,c) if code == 0 else op[name](a,b)
            values.append((code << 64) | (a << 48) | (b << 32) | (c << 16) | y)
    return values


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--seed', type=int, default=20261117)
    p.add_argument('--random', type=int, default=3000)
    a=p.parse_args()
    words = vectors(a.seed,a.random)
    a.out.write_text(''.join(f'{v:017x}\n' for v in words))
    print(f'{len(words)} SoftFloat arithmetic vectors')
