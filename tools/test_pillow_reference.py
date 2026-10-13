"""Run with python -B -m unittest discover -s tools -p test_pillow_reference.py."""

import struct
import unittest

from generate_png_regression_fixtures import png
from pillow_reference import reference_rgba
from verify_decoders import source_images


class PillowReferenceTests(unittest.TestCase):
    def test_gray16_uses_high_byte(self):
        samples = [[(value,) for value in (0, 1, 255, 256, 32768, 65535)]]
        result = reference_rgba(png(samples, 16, 0, False))
        expected = bytes(channel for value in (0, 0, 0, 1, 128, 255)
                         for channel in (value, value, value, 255))
        self.assertEqual(result.tobytes(), expected)

    def test_gray16_transparency_uses_original_precision(self):
        samples = [[(0x1234,), (0x1235,), (0x1200,)]]
        data = png(samples, 16, 0, False, transparency=struct.pack(">H", 0x1234))
        expected = bytes([18, 18, 18, 0, 18, 18, 18, 255, 18, 18, 18, 255])
        self.assertEqual(reference_rgba(data).tobytes(), expected)

    def test_rgb16_transparency_adam7_and_all_filters(self):
        key = (0x1234, 0x5678, 0x9ABC)
        near = (0x1235, 0x5678, 0x9ABC)
        samples = [[key if (x + y) % 2 else near for x in range(9)] for y in range(9)]
        transparency = struct.pack(">HHH", *key)
        expected = bytes(channel for row in samples for sample in row
                         for channel in (*[value >> 8 for value in sample],
                                         0 if sample == key else 255))
        for interlaced in (False, True):
            with self.subTest(interlaced=interlaced):
                data = png(samples, 16, 2, interlaced, transparency=transparency)
                self.assertEqual(reference_rgba(data).tobytes(), expected)

    def test_png3_masks_unused_transparency_bits(self):
        for depth in (1, 2, 4, 8):
            mask = (1 << depth) - 1
            key = 1
            data = png([[(key,), (0,)]], depth, 0, False,
                       transparency=struct.pack(">H", key | (0xFFFF ^ mask)))
            value = 255 // mask
            self.assertEqual(reference_rgba(data).tobytes(),
                             bytes([value, value, value, 0, 0, 0, 0, 255]))
        key = (1, 17, 65)
        data = png([[key, (2, 17, 65)]], 8, 2, False,
                   transparency=struct.pack(">HHH", *(value | 0xFF00 for value in key)))
        self.assertEqual(reference_rgba(data).tobytes(), bytes([*key, 0, 2, 17, 65, 255]))

    def test_failed_originals_do_not_abort_derivative_generation(self):
        valid = png([[(32768,)]], 16, 0, False)
        sources = [("corrupt.png", b"invalid", None),
                   ("unreadable.png", None, "permission denied"),
                   ("valid.png", valid, None)]
        derived = list(source_images(sources, 16))
        self.assertEqual([name for name, _ in derived],
                         ["valid.png", "pattern_RGB", "pattern_RGBA", "pattern_L", "pattern_LA"])
        self.assertEqual(derived[0][1].tobytes(), bytes([128, 128, 128, 255]))


if __name__ == "__main__":
    unittest.main()
