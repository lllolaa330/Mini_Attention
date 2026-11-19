import unittest

from model.attention import encode
from model.scope_attention import bit_model_with_probabilities, scna_exp16
from model.softfloat import ops


class ScopeModelTests(unittest.TestCase):
    def test_quantized_checkpoint_landmarks(self):
        op = ops()
        for x, expected in [(0, 0x3bfe), (-1, 0x35ce), (-4, 0x23e2), (-8, 0)]:
            with self.subTest(x=x):
                self.assertEqual(scna_exp16(encode(x), op), expected)

    def test_one_nonzero_numerator_and_subunit_denominator(self):
        # Every score row is [16, -16, ...]. SCNA(-32)=0 and SCNA(0)<1.
        # Division by the subunit row sum must still produce one exactly.
        q = [0x4000] * 256
        k = [0x4000] * 16 + [0xc000] * 240
        v_first = [encode((j-8)/8) for j in range(16)]
        v = v_first + [0x4000] * 240
        y, p = bit_model_with_probabilities(q+k+v)
        self.assertEqual(p, ([0x3c00]+[0]*15)*16)
        self.assertEqual(y, v_first*16)
