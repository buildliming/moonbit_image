"""Run with python -B -m unittest discover -s tools -p test_pillow_reference.py."""

import struct
from io import BytesIO
from pathlib import Path
import shutil
import tempfile
import unittest

from PIL import Image
from generate_png_regression_fixtures import png
from pillow_reference import reference_rgba
from verify_decoders import (DecoderWorker, complex_patterns, encoded_variants,
                             source_images, visual_variants)


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


class ComplexCorpusTests(unittest.TestCase):
    def test_gradient_endpoints_alpha_and_size_bound(self):
        patterns = dict(complex_patterns(16))
        for image in patterns.values():
            self.assertLessEqual(max(image.size), 16)
        smooth = patterns["smooth_gradient"]
        self.assertEqual(smooth.getpixel((0, 0)), (0, 0, 0))
        self.assertEqual(smooth.getpixel((smooth.width - 1, smooth.height - 1)), (255, 255, 255))
        self.assertEqual(patterns["radial_alpha"].getchannel("A").getextrema()[1], 255)
        self.assertEqual(patterns["narrow_vertical"].width, 1)
        self.assertEqual(patterns["narrow_horizontal"].height, 1)

    def test_blurs_preserve_source_and_motion_direction(self):
        source = Image.new("RGB", (11, 11))
        source.putpixel((5, 5), (255, 255, 255))
        variants = dict(visual_variants(source, True))
        self.assertEqual(source.getpixel((5, 5)), (255, 255, 255))
        for name, image in variants.items():
            self.assertEqual(image.size, source.size)
            if name != "original":
                self.assertNotEqual(image.tobytes(), source.tobytes())
        motion = variants["motion_horizontal_5"]
        self.assertEqual(motion.getpixel((4, 5)), (51, 51, 51))
        self.assertEqual(motion.getpixel((5, 4)), (0, 0, 0))

    def test_encoding_matrix_uses_real_progressive_streams_and_all_six_formats(self):
        for mode in ("L", "LA", "RGB", "RGBA"):
            with self.subTest(mode=mode):
                image = Image.new(mode, (17, 19))
                formats, progressive_sampling = set(), set()
                for fmt, options, encoded in encoded_variants(image, True):
                    formats.add(fmt)
                    with Image.open(BytesIO(encoded)) as decoded:
                        self.assertEqual(decoded.format, fmt)
                        self.assertEqual(decoded.size, image.size)
                        if fmt == "JPEG":
                            self.assertEqual(bool(decoded.info.get("progressive")), options["progressive"])
                            if options["progressive"]:
                                progressive_sampling.add(options["subsampling"])
                    self.assertEqual(reference_rgba(encoded).size, image.size)
                self.assertEqual(formats, {"BMP", "PNG", "TGA", "QOI", "GIF", "JPEG"})
                self.assertEqual(progressive_sampling, {0, 1, 2})

    @unittest.skipUnless(shutil.which("node"), "Node.js is required for the worker recovery test")
    def test_worker_recovers_after_failure_crash_and_timeout(self):
        # Exercise real subprocess lifecycle and pipe handling, including a
        # stale pixel file left by the previous successful request.
        script = r'''
const fs = require('node:fs');
require('node:readline').createInterface({input: process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  const value = fs.readFileSync(request.input).toString();
  if (value === 'crash') process.exit(3);
  if (value === 'hang') return;
  if (value === 'failure') { console.log(JSON.stringify({error:'bad image'})); return; }
  fs.writeFileSync(request.output, Buffer.from([17, 31, 47, 255]));
  console.log(JSON.stringify({width:1,height:1,decode_ms:0}));
});
'''
        build = Path(__file__).resolve().parents[1] / "_build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="reference-worker-test-", dir=build) as temporary:
            work = Path(temporary)
            entry = work / "worker.js"
            entry.write_text(script, encoding="utf-8")
            worker = DecoderWorker(entry, work, 1)
            try:
                _, pixels = worker.decode(b"valid")
                self.assertEqual(pixels, bytes([17, 31, 47, 255]))
                process = worker.process
                with self.assertRaisesRegex(ValueError, "bad image"):
                    worker.decode(b"failure")
                self.assertIs(worker.process, process)
                for value, exception in ((b"crash", RuntimeError), (b"hang", TimeoutError)):
                    with self.subTest(value=value):
                        with self.assertRaises(exception):
                            worker.decode(value)
                        _, pixels = worker.decode(b"valid")
                        self.assertEqual(pixels, bytes([17, 31, 47, 255]))
            finally:
                worker.close()


if __name__ == "__main__":
    unittest.main()
