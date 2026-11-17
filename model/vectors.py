"""Reproducible directed and random full-frame fixtures."""
import random
from .attention import encode


def make_cases(seed=20261022, random_count=32):
    rng = random.Random(seed)
    cases = []

    def add(name, category, q, k, v, bits=False):
        words = q + k + v
        cases.append({'name': name, 'category': category,
                      'words': words if bits else list(map(encode, words))})

    z = [0.0] * 256
    pos, neg = [2.0] * 256, [-2.0] * 256
    checker = [2.0 if (r+c) % 2 else -2.0 for r in range(16) for c in range(16)]
    ramp = [(r*16+c-127.5)/64 for r in range(16) for c in range(16)]
    add('all_zero', 'zero', z, z, z)
    add('all_negative_zero', 'zero', [0x8000]*256, [0x8000]*256, [0x8000]*256, True)
    add('all_positive_extreme', 'extreme', pos, pos, pos)
    add('all_negative_extreme', 'extreme', neg, neg, neg)
    add('minimum_scores', 'extreme', pos, neg, ramp)
    add('checker_cancellation', 'cancellation', checker, checker, checker)
    add('exact_zero_weighted_sum', 'cancellation', z, pos, checker)
    add('uniform_weights_ramp', 'structure', z, checker, ramp)
    add('constant_v', 'structure', ramp, checker, [1.125]*256)
    identity = [2.0 if r == c else 0.0 for r in range(16) for c in range(16)]
    add('identity_transpose_probe', 'structure', identity, ramp, identity)
    add('sharp_max_gap_32', 'extreme', pos,
        [2.0 if r == 3 else -2.0 for r in range(16) for _ in range(16)], ramp)
    add('tied_maxima', 'structure', pos,
        [2.0 if r % 3 == 0 else -2.0 for r in range(16) for _ in range(16)], checker)
    # At and immediately around exp cutoff and grid rounding boundaries.
    for eps in (-1/1024, 0.0, 1/1024):
        # Vary the maximum, keeping all keys legal on both sides of gap=16.
        keys = [eps if r == 0 else -2.0 for r in range(16) for _ in range(16)]
        add(f'cutoff_{eps:+.7f}', 'boundary', pos, keys, checker)
    small = [((i % 1024) | (0x8000 if i % 3 == 0 else 0)) for i in range(256)]
    add('subnormal_and_signed_zero', 'boundary', small, small[::-1], small, True)
    edge_bits = [0x0000, 0x8000, 0x0001, 0x8001, 0x03ff, 0x83ff,
                 0x0400, 0x8400, 0x3fff, 0xbfff, 0x4000, 0xc000]
    add('binary16_boundaries', 'boundary', *[[rng.choice(edge_bits) for _ in range(256)] for _ in range(3)], bits=True)
    for i in range(random_count):
        if i % 3 == 0:
            words = [rng.randrange(0x4001) | (rng.randrange(2) << 15) for _ in range(768)]
            add(f'random_bits_{i:03d}', 'random', words[:256], words[256:512], words[512:], True)
        elif i % 3 == 1:
            values = [rng.uniform(-2, 2) for _ in range(768)]
            add(f'random_uniform_{i:03d}', 'random', values[:256], values[256:512], values[512:])
        else:
            values = [rng.choice((-2.0, 2.0)) for _ in range(768)]
            add(f'random_extremes_{i:03d}', 'random', values[:256], values[256:512], values[512:])
    return cases
