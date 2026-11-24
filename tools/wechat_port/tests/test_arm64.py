import unittest

from wechat_port.arm64 import (
    decode_insn,
    normalize_word,
    shape_word,
    sign_extend,
    data_refs,
)


class Arm64Tests(unittest.TestCase):
    def test_sign_extend(self):
        self.assertEqual(sign_extend(0x1, 1), -1)
        self.assertEqual(sign_extend(0x7FFFF, 19), -1)
        self.assertEqual(sign_extend(0x3, 2), -1)

    def test_branch_normalisation_masks_target(self):
        forward = 0x94000040
        backward = 0x97FFFFC0
        self.assertEqual(normalize_word(forward), normalize_word(backward))

    def test_mov_wide_shape_masks_immediate(self):
        mov_e0 = 0x52801C00
        mov_168 = 0x52802D00
        self.assertNotEqual(mov_e0, mov_168)
        self.assertEqual(shape_word(mov_e0), shape_word(mov_168))

    def test_decode_bl(self):
        word = 0x94000400
        insn = decode_insn(word, 0x1000)
        self.assertEqual(insn.kind, "bl")
        self.assertEqual(insn.target, 0x2000)

    def test_decode_stp_post_index(self):
        insn = decode_insn(0xA887FC08, 0x1000)
        self.assertEqual(insn.kind, "stp")
        self.assertEqual(insn.rn, 0)
        self.assertEqual(insn.rt, 8)
        self.assertEqual(insn.rt2, 31)

    def test_decode_movz(self):
        insn = decode_insn(0x52801C00, 0x1000)
        self.assertEqual(insn.kind, "mov_wide")
        self.assertEqual(insn.rd, 0)
        self.assertEqual(insn.imm, 0xE0)

    def test_data_refs(self):
        words = [0x90000008, 0x91004108, 0xF9000008]
        refs = data_refs(words, 0x1000)
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0].target, 0x1010)
        self.assertEqual(refs[0].kind, "add")


if __name__ == "__main__":
    unittest.main()
