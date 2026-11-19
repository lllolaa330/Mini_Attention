"""Bit-exact binary16 model of the 16x16 SCOPE Attention implementation."""
from .attention import N, decode, sum16_balanced, validate
from .softfloat import ops


# RNE(binary16) of the fused SCNA-8 Exp coefficients in checkpoint order.
# Reproduce from the authors' checkpoint with scripts/gen_scope_exp.py.
# Source, exact revision and adaptation notes: third_party/scope/README.md.
EXP_COEFFICIENTS = (
    (0x1f19, 0x2977), (0x3122, 0x3133), (0x2f9a, 0x31af), (0x2aa8, 0x30c6),
    (0x340e, 0x2c41), (0x26ab, 0x2eb2), (0x3273, 0x2fd9), (0x2d4e, 0x318c),
)


def scna_exp16(x, op):
    """Eight positive affine/ReLU terms, one FP16 addition per physical row."""
    total = 0
    for w, b in EXP_COEFFICIENTS:
        affine = op['fma'](x, w, b)
        activation = 0 if affine & 0x8000 else affine
        total = op['add'](total, activation)
    return total


def dot16(a, b, fma):
    acc = 0
    for x, y in zip(a, b):
        acc = fma(x, y, acc)
    return acc


def bit_model_with_probabilities(words):
    """Return row-major Y and P as binary16 bit patterns."""
    validate(words)
    op = ops()
    q, k, v = (words[j:j+N*N] for j in range(0, len(words), N*N))
    result, probabilities = [], []
    for i in range(N):
        row = q[i*N:(i+1)*N]
        scores = [
            op['mul'](dot16(row, k[j*N:(j+1)*N], op['fma']), 0x3400)
            for j in range(N)
        ]
        largest = max(scores, key=decode)
        exponentials = [scna_exp16(op['sub'](score, largest), op) for score in scores]
        denominator = sum16_balanced(exponentials, op['add'])
        p_row = [op['div'](e, denominator) for e in exponentials]
        probabilities.extend(p_row)
        result.extend(dot16(p_row, v[j::N], op['fma']) for j in range(N))
    return result, probabilities


def bit_model(words):
    return bit_model_with_probabilities(words)[0]
