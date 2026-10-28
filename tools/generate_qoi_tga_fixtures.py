"""Generate QOI/TGA regressions from independent samples; verify with Pillow.

Run: python tools/generate_qoi_tga_fixtures.py, then moon fmt.
Requires Pillow. Generated MoonBit tests require no Python or filesystem access.
"""
from io import BytesIO
from pathlib import Path
import struct

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
END = bytes(7) + b"\1"


def qoi(width, height, chunks, channels=4):
    return b"qoif" + struct.pack(">IIBB", width, height, channels, 0) + chunks + END


def literal(data):
    return 'b"' + "".join(f"\\x{value:02X}" for value in data) + '"'


tests = []


def good(name, data, expected, width, height, reference=True):
    if reference:
        actual = Image.open(BytesIO(data)).convert("RGBA")
        assert actual.size == (width, height), name
        assert actual.tobytes() == expected, name
    tests.append(f'''///|
test "stability_{name}" {{
  stability_pixels({literal(data)}, {width}, {height}, {literal(expected)})
}}
''')


def bad(name, data, decoder):
    tests.append(f'''///|
test "stability_{name}" {{
  let rejected = try {{
    let _ = @image.{decoder}({literal(data)})
    false
  }} catch {{ _ => true }}
  assert_true(rejected)
}}
''')


good("qoi_initial_transparent_cache", qoi(1, 1, b"\x35"), bytes(4), 1, 1)
good("qoi_initial_opaque_run", qoi(62, 1, b"\xfd"), bytes([0, 0, 0, 255]) * 62, 62, 1)
good("qoi_diff_wrap", qoi(1, 1, b"\x40"), bytes([254, 254, 254, 255]), 1, 1)
good("qoi_luma_wrap", qoi(1, 1, b"\x80\x00"), bytes([216, 224, 216, 255]), 1, 1)
good("qoi_rgb_preserves_alpha", qoi(2, 1, b"\xff\x01\x02\x03\x04\xfe\x05\x06\x07"),
     bytes([1, 2, 3, 4, 5, 6, 7, 4]), 2, 1)
good("qoi_channels_are_informative", qoi(1, 1, b"\xff\x01\x02\x03\x04", channels=3),
     bytes([1, 2, 3, 4]), 1, 1, reference=False)
base = qoi(1, 1, b"\xfe\x0A\x14\x1E")
for label, data in [
    ("marker", base[:-1] + b"\x02"), ("missing_pixel", qoi(1, 1, b"")),
    ("truncated_rgb", qoi(1, 1, b"\xfe\x01\x02")),
    ("truncated_rgba", qoi(1, 1, b"\xff\x01\x02\x03")),
    ("truncated_luma", qoi(1, 1, b"\x80")),
    ("run_overflow", qoi(1, 1, b"\xc1")),
    ("extra_pixels", qoi(1, 1, b"\xc0\xc0")),
    ("oversize", qoi(65536, 65536, b"\xc0")),
    ("resource_limit", qoi(10000, 10000, b"\xc0")),
]:
    bad("qoi_reject_" + label, data, "decode_qoi")


def tga_header(w, h, depth, kind, descriptor):
    return struct.pack("<BBBHHBHHHHBB", 0, 0, kind, 0, 0, 0, 0, 0, w, h, depth, descriptor)


colors = [(248, 0, 0, 255), (0, 248, 0, 255), (0, 0, 248, 255),
          (248, 248, 0, 255), (0, 248, 248, 255), (248, 0, 248, 255)]
for depth in [8, 16, 24, 32]:
    grayscale = depth in [8, 16]
    samples = [(value, value, value, (index * 41 if depth == 16 else 255))
               for index, value in enumerate([0, 40, 90, 130, 200, 255])] if grayscale else colors
    for origin in range(4):
        for rle in [False, True]:
            pixels = bytearray()
            ys = range(2) if origin & 2 else reversed(range(2))
            xs = list(reversed(range(3))) if origin & 1 else list(range(3))
            for y in ys:
                for x in xs:
                    r, g, b, a = samples[y * 3 + x]
                    pixels.extend(bytes([r, a]) if depth == 16 else bytes([r]) if depth == 8
                                  else bytes([b, g, r, a]) if depth == 32 else bytes([b, g, r]))
            kind = (3 if grayscale else 2) + (8 if rle else 0)
            descriptor = (origin << 4) | (8 if depth in [16, 32] else 0)
            data = tga_header(3, 2, depth, kind, descriptor)
            data += (b"\x05" if rle else b"") + pixels
            # Pillow handles all four origins, including grayscale+alpha.
            good(f"tga_{depth}_{origin}_{'rle' if rle else 'raw'}", data,
                 bytes(v for p in samples for v in p), 3, 2)

for attributes in [0, 1]:
    for rle in [False, True]:
        data = tga_header(2, 1, 16, 10 if rle else 2, 32 | attributes)
        data += (b"\x81" if rle else b"") + b"\x00\x7c" * (1 if rle else 2)
        # 16-bit Truevision BGR555 plus optional one-bit attribute.
        good(f"tga_16bit_truecolor_alpha{attributes}_{rle}", data,
             bytes([255, 0, 0, 0 if attributes else 255]) * 2, 2, 1, reference=False)

footer = bytes(8) + b"TRUEVISION-XFILE.\0"
good("tga_v2_footer", tga_header(1, 1, 24, 2, 32) + b"\x03\x02\x01" + footer,
     bytes([1, 2, 3, 255]), 1, 1)
for label, data in [
    ("truecolor8", tga_header(1, 1, 8, 2, 32) + bytes(4)),
    ("gray24", tga_header(1, 1, 24, 3, 32) + bytes(4)),
    ("interleaved", tga_header(1, 1, 24, 2, 96) + bytes(4)),
    ("attributes", tga_header(1, 1, 24, 2, 40) + bytes(4)),
    ("oversize", tga_header(65535, 65535, 32, 2, 40)),
    ("rle_oversize", tga_header(65535, 65535, 32, 10, 40)),
    ("rle_overflow", tga_header(1, 1, 24, 10, 32) + b"\x81\x00\x00\x00"),
    ("short_pixel", tga_header(1, 1, 24, 2, 32) + b"\x00\x00"),
    ("short_rle", tga_header(2, 1, 24, 10, 32) + b"\x81\x00\x00"),
]:
    bad("tga_reject_" + label, data, "decode_tga")

header = '''// Generated by tools/generate_qoi_tga_fixtures.py using independent samples/Pillow.
///|
fn stability_pixels(data : Bytes, w : Int, h : Int, expected : Bytes) -> Unit raise {
  let image = @image.decode(data)
  assert_eq(image.width, w)
  assert_eq(image.height, h)
  assert_eq(image.to_rgba8().data, expected)
  let (width, height, _) = @image.image_dimensions(data)
  assert_eq(width, w)
  assert_eq(height, h)
}

///|
test "stability_qoi_encoder_cache_roundtrip" {
  // Before 433b856, the encoder used an opaque initial cache and emitted
  // this stream for opaque red/black. Under QOI's zero-initialized cache,
  // INDEX 53 means transparent black, even with a three-channel header.
  // Preserve standard decoding; legacy files require explicit migration.
  let legacy = b"qoif\\x00\\x00\\x00\\x02\\x00\\x00\\x00\\x01\\x03\\x00\\xFE\\xFF\\x00\\x00\\x35\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x01"
  assert_eq(@image.decode_qoi(legacy).data, b"\\xFF\\x00\\x00\\xFF\\x00\\x00\\x00\\x00")
  let pixels = b"\\xFF\\x00\\x00\\xFF\\x00\\x00\\x00\\xFF"
  let image = @image.decode_qoi(b"qoif\\x00\\x00\\x00\\x02\\x00\\x00\\x00\\x01\\x04\\x00\\xFE\\xFF\\x00\\x00\\xFE\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x01")
  assert_eq(@image.decode_qoi(@image.encode_qoi(image)).data, pixels)
}

'''
(ROOT / "qoi_tga_regression_test.mbt").write_text(header + "\n".join(tests), encoding="utf-8")
print(f"Generated {len(tests) + 1} QOI/TGA regressions")
