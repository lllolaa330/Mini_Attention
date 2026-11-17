#!/usr/bin/env python3
"""Generate/check binary16 exp(-x) ROM with Decimal precision and direct RNE."""
import argparse
import bisect
from decimal import Decimal, localcontext
from pathlib import Path
import struct
ROOT = Path(__file__).resolve().parents[1]


def decode(word):
    return struct.unpack('>e', struct.pack('>H', word))[0]


HALF = [Decimal.from_float(decode(w)) for w in range(0x3c01)]


def table(precision):
    result = []
    with localcontext() as ctx:
        ctx.prec = precision
        for mag in range(0x4c57):
            y = (-Decimal.from_float(decode(mag))).exp()
            hi = bisect.bisect_left(HALF, y)
            if hi == 0 or HALF[hi] == y:
                word = hi
            else:
                lo = hi-1
                mid = (HALF[lo]+HALF[hi])/2
                word = lo if y < mid or (y == mid and not (lo & 1)) else hi
            result.append(word)
    assert result[0] == 0x3c00 and result[-2] == 1 and result[-1] == 0
    return result[:-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    a, b = table(80), table(110)
    assert a == b, 'exp rounding not stable across independent precision levels'
    text = ''.join(f'{x:04x}\n' for x in a)
    path = ROOT/'rtl/exp_fp16.hex'
    if args.check:
        assert path.read_text() == text, 'ROM differs from high-precision regeneration'
    else:
        path.write_text(text)
    print(f'EXP ROM PASS: {len(a)} entries, Decimal 80/110 digits agree; cutoff 0x4c56')


if __name__ == '__main__':
    main()
