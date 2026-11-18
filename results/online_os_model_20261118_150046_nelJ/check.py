"""Check full online-normalization rows with an independent per-operation binary16 oracle."""
import csv
import hashlib
import json
import math
from pathlib import Path
import platform
import struct
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import bit_model_with_probabilities, decode, encode, errors, reference
from model.softfloat import ops
from model.vectors import make_cases


def half(x):
    return struct.unpack('>e', struct.pack('>e', x))[0]


def expected_probabilities(words, op):
    result = []
    for i in range(16):
        scores = []
        for j in range(16):
            acc = 0
            for k in range(16):
                acc = op['fma'](words[16*i+k], words[256+16*j+k], acc)
            scores.append(half(decode(acc) * .25))
        m, ell = scores[0], 1.
        for score in scores[1:]:
            new_m = max(m, score)
            scale = half(math.exp(half(m - new_m)))
            term = half(math.exp(half(score - new_m)))
            ell = half(half(ell * scale) + term)
            m = new_m
        for score in scores:
            numerator = half(math.exp(half(score - m)))
            result.append(encode(numerator / ell))
    return result


cases = make_cases(seed=20261117, random_count=64)
rows = []
op = ops()
for case in cases:
    y, p = bit_model_with_probabilities(case['words'])
    expected = expected_probabilities(case['words'], op)
    if expected != p:
        raise AssertionError(case['name'])
    rmse, max_error = errors(y, reference(case['words']))
    assert rmse <= .06 and max_error <= .20, case['name']
    rows.append({'case': case['name'], 'p_words_matched': len(p), 'y_words': len(y),
                 'rmse': rmse, 'max_abs_error': max_error})
with (HERE / 'per_case.csv').open('w') as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
sources = ['model/attention.py', 'model/vectors.py', 'model/softfloat.py',
           'model/softfloat_bridge.c', 'tests/test_model.py', 'rtl/exp_fp16.hex']
summary = {
    'status': 'PASS', 'scope': 'Software model only. QK FMA uses SoftFloat in both paths. '
        'The independent online row oracle uses the two exponential terms of the recurrence, '
        'Python math.exp, and binary16 rounding through struct. Float64 Y is a separate mathematical reference.',
    'command': 'python3 ' + str(Path(__file__).resolve().relative_to(ROOT)),
    'python': platform.python_version(), 'seed': 20261117,
    'directed_frames': 17, 'random_frames': 64,
    'rows': len(rows)*16, 'p_words_matched': sum(row['p_words_matched'] for row in rows),
    'y_words_with_float64_reference': sum(row['y_words'] for row in rows),
    'max_frame_rmse': max(row['rmse'] for row in rows),
    'max_abs_error': max(row['max_abs_error'] for row in rows),
    'tolerance': {'frame_rmse': .06, 'max_abs_error': .20},
    'sources_sha256': {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources},
}
(HERE / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(HERE, summary['p_words_matched'], summary['max_frame_rmse'], summary['max_abs_error'])
