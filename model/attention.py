"""Bit model: FP16 FMA/Softmax/PV; separate unapproximated float64 reference."""
from functools import lru_cache
import math
from pathlib import Path
import struct
from .softfloat import ops
N = 16
ROOT = Path(__file__).resolve().parents[1]


def decode(h):
    return struct.unpack('>e', struct.pack('>H', h))[0]


def encode(x):
    return struct.unpack('>H', struct.pack('>e', x))[0]


def validate(words):
    if len(words) != 768:
        raise ValueError('Expected 768 binary16 Q/K/V words')
    for h in words:
        if not isinstance(h, int) or not 0 <= h <= 65535 or not math.isfinite(decode(h)) or abs(decode(h)) > 2:
            raise ValueError('Input outside finite binary16 [-2,2]')


@lru_cache(maxsize=1)
def exp_table():
    words = [int(s, 16) for s in (ROOT/'rtl/exp_fp16.hex').read_text().split()]
    if len(words) != 0x4c56:
        raise ValueError('Unexpected exp ROM size')
    return words


def exp16(x):
    if decode(x) > 0:
        raise ValueError('Stable softmax exp input must be nonpositive')
    mag = x & 0x7fff
    return exp_table()[mag] if mag < 0x4c56 else 0


def sum16_balanced(values, add=None):
    """16 leaves -> 8 -> 4 -> 2 -> 1, with binary16 RNE at each node.

    Matches GEN_SUM_L1/L2/L3 and add_final in softmax_fp16. Pairing is
    adjacent in the original column order; no reassociation is permitted.
    """
    if len(values) != 16:
        raise ValueError('Balanced Softmax reduction requires exactly 16 leaves')
    if add is None:
        add = ops()['add']
    level = list(values)
    while len(level) > 1:
        level = [add(level[j], level[j+1]) for j in range(0, len(level), 2)]
    return level[0]


def bit_model(words):
    validate(words)
    op = ops()
    q, k, v = [words[offset:offset+256] for offset in (0, 256, 512)]
    result = []
    for i in range(N):
        scores = []
        for j in range(N):
            acc = 0
            for t in range(N):
                acc = op['fma'](q[i*N+t], k[j*N+t], acc)
            scores.append(op['mul'](acc, 0x3400))
        maximum = max(scores, key=decode)
        weights = [exp16(op['sub'](s, maximum)) for s in scores]
        den = sum16_balanced(weights, op['add'])
        assert 1 <= decode(den) <= 16
        probabilities = [op['div'](w, den) for w in weights]
        for j in range(N):
            acc = 0
            for t in range(N):
                acc = op['fma'](probabilities[t], v[t*N+j], acc)
            result.append(acc)
    return result


def reference(words):
    validate(words)
    q, k, v = [[decode(h) for h in words[a:a+256]] for a in (0, 256, 512)]
    out = []
    for row in range(N):
        scores = [math.fsum(q[row*N+t]*k[col*N+t] for t in range(N))/4 for col in range(N)]
        maximum = max(scores)
        weights = [math.exp(s-maximum) for s in scores]
        den = math.fsum(weights)
        out.extend(math.fsum(weights[t]*v[t*N+col] for t in range(N))/den for col in range(N))
    return out


def errors(actual, ref):
    if len(actual) != 256 or not all(math.isfinite(decode(h)) for h in actual):
        raise ValueError('Expected 256 finite outputs')
    differences = [decode(h)-r for h,r in zip(actual,ref)]
    return math.sqrt(math.fsum(x*x for x in differences)/256), max(map(abs,differences))
