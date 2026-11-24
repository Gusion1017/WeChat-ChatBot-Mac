import os
import struct
import tempfile
import unittest

from wechat_port.macho import MachOImage, _uleb


def build_minimal_macho():
    header_size = 32
    seg_size = 72 + 80
    sizeofcmds = seg_size + 16
    data = bytearray(0x1000)
    struct.pack_into("<IiiIIIII", data, 0, 0xFEEDFACF, 0x0100000C, 0, 6, 2, sizeofcmds, 0, 0)
    off = header_size
    struct.pack_into("<II", data, off, 0x19, seg_size)
    data[off + 8 : off + 24] = b"__TEXT\0".ljust(16, b"\0")
    struct.pack_into("<QQQQIIII", data, off + 24, 0, 0x1000, 0, 0x1000, 5, 5, 1, 0)
    sect = off + 72
    data[sect : sect + 16] = b"__text\0".ljust(16, b"\0")
    data[sect + 16 : sect + 32] = b"__TEXT\0".ljust(16, b"\0")
    struct.pack_into("<QQIIIIIIII", data, sect + 32, 0x100, 0x100, 0x100, 2, 0, 0, 0, 0, 0, 0)
    off += seg_size
    struct.pack_into("<II", data, off, 0x26, 16)
    struct.pack_into("<II", data, off + 8, 0x300, 8)
    data[0x300 : 0x303] = bytes([0x80, 0x02, 0x20])
    data[0x303] = 0
    return bytes(data)


class ULEBTests(unittest.TestCase):
    def test_uleb(self):
        self.assertEqual(_uleb(bytes([0x80, 0x02]), 0), (0x100, 2))
        self.assertEqual(_uleb(bytes([0x7F]), 0), (0x7F, 1))


class MachOTests(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".dylib")
        os.close(fd)
        with open(self.path, "wb") as fh:
            fh.write(build_minimal_macho())
        self.addCleanup(os.unlink, self.path)

    def test_starts_and_sections(self):
        image = MachOImage(self.path)
        try:
            self.assertEqual(list(image.starts), [0x100, 0x120])
            self.assertEqual(image.text_start, 0x100)
            self.assertEqual(image.text_end, 0x200)
            self.assertIsNotNone(image.section_at(0x180))
            self.assertIsNone(image.section_at(0x900))
        finally:
            image.close()


if __name__ == "__main__":
    unittest.main()
