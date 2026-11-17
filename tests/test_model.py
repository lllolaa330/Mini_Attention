import unittest
import math
from model.attention import bit_model, decode, encode, exp16, exp_table, reference, validate
from model.softfloat import ops


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

    def test_invalid_inputs(self):
        for words in ([0], [0x7c00]*768, [0x7e00]*768, [0x4001]*768):
            with self.assertRaises(ValueError): validate(words)


if __name__ == '__main__': unittest.main()
