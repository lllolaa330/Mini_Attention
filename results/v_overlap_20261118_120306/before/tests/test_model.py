import unittest
import math
from model.attention import bit_model, decode, encode, exp16, exp_table, reference, sum16_balanced, validate
from model.softfloat import ops
from model.vectors import make_cases


class TestModel(unittest.TestCase):
    def test_subnormal_and_rounding(self):
        op = ops()
        self.assertEqual(op['fma'](1, 0x3c00, 0), 1)
        self.assertEqual(op['mul'](1, 0x3800), 0)  # half a minimum subnormal ties to zero
        self.assertEqual(op['mul'](3, 0x3800), 2)  # 1.5 minimum subnormals ties to even
        self.assertEqual(op['add'](0x3c00, 0x1000), 0x3c00)  # 1 + 2^-11
        self.assertEqual(op['div'](0x3c00, 0x4000), 0x3800)

    def test_exp_boundaries(self):
        self.assertEqual(exp16(0), 0x3c00)
        self.assertEqual(exp16(0x8000), 0x3c00)
        self.assertEqual(exp16(0xcc55), 1)
        self.assertEqual(exp16(0xcc56), 0)
        self.assertEqual(exp16(0xd000), 0)

    def test_analytical_zero_and_constant(self):
        self.assertEqual(bit_model([0]*768), [0]*256)
        words = [0]*512 + [encode(1.125)]*256
        self.assertEqual(bit_model(words), [encode(1.125)]*256)
        self.assertEqual(reference(words), [1.125]*256)

    def test_exp_independent_binary64(self):
        for mag, word in enumerate(exp_table()):
            self.assertEqual(word, encode(math.exp(-decode(mag))), hex(mag))
        self.assertEqual(encode(math.exp(-decode(0x4c56))), 0)

    def test_balanced_sum_rounding_contract(self):
        # Serial addition loses every half-ulp increment to ties-to-even.
        # The RTL tree combines small terms before adding to the larger one.
        values = [0x3c00] + [0x1000]*15  # 1 followed by fifteen 2^-11 terms
        sequential = 0
        for value in values:
            sequential = ops()['add'](sequential, value)
        self.assertEqual(sequential, 0x3c00)
        self.assertEqual(sum16_balanced(values), 0x3c07)
        with self.assertRaises(ValueError):
            sum16_balanced(values[:15])

    def test_parallel_softmax_regression_case9(self):
        # Former mismatch: identity_transpose_probe, row0,col1.
        # Derive the row independently to expose the changed denominator.
        case = make_cases(random_count=0)[9]
        self.assertEqual(case['name'], 'identity_transpose_probe')
        q, k, v = [case['words'][a:a+256] for a in (0,256,512)]
        op = ops()
        scores = []
        for j in range(16):
            acc = 0
            for t in range(16):
                acc = op['fma'](q[t], k[j*16+t], acc)
            scores.append(op['mul'](acc, 0x3400))
        maximum = max(scores, key=decode)
        weights = [exp16(op['sub'](s, maximum)) for s in scores]
        serial = 0
        for w in weights:
            serial = op['add'](serial, w)
        tree = sum16_balanced(weights)
        self.assertEqual(serial, 0x475c)  # 7.359375
        self.assertEqual(tree, 0x475d)    # 7.36328125
        outputs = []
        for denominator in (serial, tree):
            y = 0
            for t in range(16):
                p = op['div'](weights[t], denominator)
                y = op['fma'](p, v[t*16+1], y)
            outputs.append(y)
        self.assertEqual(outputs, [0x2a0c, 0x2a0b])
        self.assertEqual(bit_model(case['words'])[1], 0x2a0b)

    def test_invalid_inputs(self):
        for words in ([0], [0x7c00]*768, [0x7e00]*768, [0x4001]*768):
            with self.assertRaises(ValueError): validate(words)


if __name__ == '__main__': unittest.main()
