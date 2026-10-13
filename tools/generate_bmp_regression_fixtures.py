"""Generate BMP regressions from constructed BMP files and Pillow pixel checks.

Run from the repository root; Pillow is required only to regenerate fixtures.
"""

from io import BytesIO
from pathlib import Path
import struct

from PIL import Image


PALETTE = [(0, 0, 0)] + [(i * 31 % 256, i * 67 % 256, i * 101 % 256) for i in range(1, 16)]


def bmp(width, height, depth, pixels, compression=0, palette=None, dib=40, masks=b""):
    palette = [] if palette is None else palette
    colors = b"".join(bytes((blue, green, red, 0)) for red, green, blue in palette)
    offset = 14 + dib + len(masks) + len(colors)
    header = struct.pack("<IiiHHIIiiII", dib, width, height, 1, depth,
                         compression, len(pixels), 0, 0, len(palette), 0)
    header += bytes(dib - 40)
    return struct.pack("<2sIHHI", b"BM", offset + len(pixels), 0, 0, offset) + header + masks + colors + pixels


def raw_image(width, height, depth, top_down):
    palette = PALETTE[:2 if depth == 1 else 16] if depth <= 8 else []
    samples = []
    packed_rows = []
    expected = bytearray()
    for y in range(height):
        row = bytearray()
        indexes = [(x + 3 * y) % len(palette) for x in range(width)] if palette else []
        for x in range(width):
            if palette:
                rgba = (*palette[indexes[x]], 255)
            else:
                rgba = ((x * 31 + y * 17) % 256, (x * 67 + y * 13) % 256,
                        (x * 101 + y * 29) % 256, (x * 41 + y * 59) % 256)
                row.extend((rgba[2], rgba[1], rgba[0]))
                if depth == 32:
                    row.append(rgba[3])
            samples.append(rgba[:3])
            expected.extend(rgba[:3] if depth == 24 else rgba)
        if depth <= 8:
            per_byte = 8 // depth
            for start in range(0, width, per_byte):
                value = 0
                for position, index in enumerate(indexes[start:start + per_byte]):
                    value |= index << (8 - depth * (position + 1))
                row.append(value)
        row.extend(bytes((-len(row)) % 4))
        packed_rows.append(bytes(row))
    payload = b"".join(packed_rows if top_down else reversed(packed_rows))
    result = bmp(width, -height if top_down else height, depth, payload, palette=palette)
    decoded = Image.open(BytesIO(result)).convert("RGB").tobytes()
    assert decoded == bytes(channel for sample in samples for channel in sample)
    return result, bytes(expected)


def mb_bytes(data):
    return "bmp_regression_bytes([" + ", ".join(f"0x{value:02X}" for value in data) + "])"


tests = []


def valid(name, data, expected, width, height, pixel_format):
    tests.append(f'''///|
test "bmp_regression_{name}" {{
  bmp_regression_check({mb_bytes(data)}, {width}, {height}, "{pixel_format}", {mb_bytes(expected)})
}}
''')


def invalid(name, data):
    tests.append(f'''///|
test "bmp_regression_reject_{name}" {{
  bmp_regression_reject({mb_bytes(data)})
}}
''')


for depth in (1, 4, 8, 24, 32):
    for top_down in (False, True):
        for width in (1, 3, 9):
            data, expected = raw_image(width, 3, depth, top_down)
            valid(f"{depth}bit_{'top_down' if top_down else 'bottom_up'}_width{width}",
                  data, expected, width, 3, "RGB8" if depth == 24 else "RGBA8")


def rle(name, depth, width, height, stream, indexes, skipped=(), odd_rle4=False):
    data = bmp(width, height, depth, bytes(stream), compression=1 if depth == 8 else 2,
               palette=PALETTE)
    expected_rgb = [PALETTE[index] for index in indexes]
    reference = data
    if odd_rle4:
        # Pillow 12.3 reads floor(n / 2) bytes for an odd RLE4 absolute run.
        # Check the spec-derived indices using an equivalent uncompressed BMP.
        rows = [bytes(indexes[y * width:(y + 1) * width]) + bytes((-width) % 4)
                for y in range(height)]
        reference = bmp(width, height, 8, b"".join(reversed(rows)), palette=PALETTE)
    decoded = Image.open(BytesIO(reference)).convert("RGB").tobytes()
    assert decoded == bytes(channel for rgb in expected_rgb for channel in rgb), name
    # Preserve the existing transparent fill for pixels omitted by RLE deltas/EOB.
    expected = bytes(channel for i, rgb in enumerate(expected_rgb)
                     for channel in (*rgb, 0 if i in skipped else 255))
    valid(name, data, expected, width, height, "RGBA8")
    return data


rle8 = rle("rle8_absolute_padding_then_encoded", 8, 5, 1,
           [0, 3, 1, 2, 3, 0, 2, 4, 0, 1], [1, 2, 3, 4, 4])
rle("rle8_rows_and_final_eol", 8, 3, 2,
    [3, 1, 0, 0, 0, 3, 2, 3, 4, 0, 0, 0, 0, 1], [2, 3, 4, 1, 1, 1])
rle("rle8_delta", 8, 4, 1,
    [1, 1, 0, 2, 1, 0, 2, 2, 0, 1], [1, 0, 2, 2], skipped=(1,))
rle4 = rle("rle4_odd_absolute_then_encoded", 4, 5, 1,
           [0, 3, 0x12, 0x30, 2, 0x45, 0, 1], [1, 2, 3, 4, 5], odd_rle4=True)
rle("rle4_word_padded_absolute", 4, 7, 1,
    [0, 5, 0x12, 0x34, 0x50, 0, 2, 0x67, 0, 1], [1, 2, 3, 4, 5, 6, 7], odd_rle4=True)
rle("rle4_rows_and_final_eol", 4, 3, 2,
    [3, 0x12, 0, 0, 3, 0x34, 0, 0, 0, 1], [3, 4, 3, 1, 2, 1])
rle("rle4_delta", 4, 4, 1,
    [1, 0x10, 0, 2, 1, 0, 2, 0x22, 0, 1], [1, 0, 2, 2], skipped=(1,))

canonical_masks = struct.pack("<III", 0x00FF0000, 0x0000FF00, 0x000000FF)
data = bmp(1, 1, 32, bytes((3, 2, 1, 64)), compression=3, masks=canonical_masks)
assert Image.open(BytesIO(data)).convert("RGB").getpixel((0, 0)) == (1, 2, 3)
valid("canonical32_bitfields", data, bytes((1, 2, 3, 64)), 1, 1, "RGBA8")
for dib in (52, 56, 108, 124):
    data = bytearray(bmp(1, 1, 32, bytes((3, 2, 1, 64)), compression=3, dib=dib))
    data[54:66] = canonical_masks
    if dib >= 56:
        data[66:70] = struct.pack("<I", 0xFF000000)
    valid(f"canonical32_bitfields_dib{dib}", bytes(data), bytes((1, 2, 3, 64)), 1, 1, "RGBA8")

base, _ = raw_image(3, 3, 24, False)
for name, offset, format, value in (
    ("zero_width", 18, "<i", 0), ("negative_width", 18, "<i", -1),
    ("zero_height", 22, "<i", 0), ("min_signed_height", 22, "<i", -2147483648),
    ("huge_dimensions", 18, "<i", 2147483647),
    ("decoded_size_limit", 18, "<i", 100000000),
    ("invalid_planes", 26, "<H", 2), ("unsupported16", 28, "<H", 16),
    ("unsupported_compression", 30, "<I", 5), ("rle8_with_rgb24", 30, "<I", 1),
    ("unsupported_dib", 14, "<I", 64), ("huge_dib", 14, "<I", 0xFFFFFFFF),
    ("offset_in_header", 10, "<I", 20), ("negative_offset", 10, "<I", 0xFFFFFFFF),
    ("offset_past_end", 10, "<I", 10000),
):
    data = bytearray(base)
    struct.pack_into(format, data, offset, value)
    invalid(name, bytes(data))
invalid("truncated_pixel_row", base[:-1])
invalid("truncated_dib", base[:40])

indexed, _ = raw_image(3, 3, 8, False)
for name, offset, value in (
    ("palette_over_bit_depth", 46, 257), ("palette_missing_before_pixels", 10, 54),
    ("truncated_palette", 10, 54 + 4 * 15), ("negative_palette_count", 46, 0xFFFFFFFF),
):
    data = bytearray(indexed)
    struct.pack_into("<I", data, offset, value)
    invalid(name, bytes(data))
for depth in (1, 4, 8):
    payload = bytes((0x80 if depth == 1 else 0x10 if depth == 4 else 1, 0, 0, 0))
    invalid(f"{depth}bit_palette_index", bmp(1, 1, depth, payload, palette=PALETTE[:1]))

data = bytearray(bmp(1, 1, 32, bytes(4), compression=3, masks=canonical_masks))
data[54:58] = struct.pack("<I", 0x000000FF)
invalid("unsupported_color_masks", bytes(data))
invalid("missing_color_masks", bmp(1, 1, 32, bytes(4), compression=3))
data = bytearray(bmp(1, 1, 32, bytes(4), compression=3, dib=56))
data[54:66] = canonical_masks
data[66:70] = struct.pack("<I", 0x0F000000)
invalid("unsupported_alpha_mask", bytes(data))

for depth in (4, 8):
    compression = 2 if depth == 4 else 1
    for name, stream in (
        ("encoded_run_overflow", [6, 0x11, 0, 1]),
        ("absolute_run_overflow", [0, 6, 0x11, 0x11, 0x11, 0, 0, 1]),
        ("delta_column_overflow", [0, 2, 6, 0, 0, 1]),
        ("delta_row_overflow", [0, 2, 0, 1, 0, 1]),
        ("truncated_delta", [0, 2, 1]),
        ("missing_eob", [1, 0x11]),
        ("write_after_final_eol", [0, 0, 1, 0x11, 0, 1]),
        ("extra_final_eol", [0, 0, 0, 0, 0, 1]),
        ("truncated_absolute", [0, 5, 0x11]),
        ("missing_word_padding", [0, 5, 0x11, 0x11, 0x11] if depth == 4 else [0, 3, 1, 1, 1]),
    ):
        invalid(f"rle{depth}_{name}", bmp(5, 1, depth, bytes(stream), compression, PALETTE))
    invalid(f"rle{depth}_top_down", bmp(5, -1, depth, bytes((0, 1)), compression, PALETTE))
    invalid(f"rle{depth}_palette_index", bmp(1, 1, depth, bytes((1, 0x10 if depth == 4 else 1, 0, 1)),
                                               compression, PALETTE[:1]))
    for name, size in (("truncated_declared_size", 2), ("declared_size_past_end", 1000)):
        data = bytearray(bmp(1, 1, depth, bytes((1, 0x11, 0, 1)), compression, PALETTE))
        struct.pack_into("<I", data, 34, size)
        invalid(f"rle{depth}_{name}", bytes(data))

source = '''// Generated by tools/generate_bmp_regression_fixtures.py.
// Pixels checked with Pillow; odd RLE4 runs use spec-derived equivalent raw BMPs.
// BGRA alpha and the transparent fill for skipped RLE pixels preserve library behavior.

///|
fn bmp_regression_bytes(values : Array[Int]) -> Bytes {
  Bytes::from_array(values.map(value => value.to_byte()))
}

///|
fn bmp_regression_check(data : Bytes, width : Int, height : Int, format : String, expected : Bytes) -> Unit raise {
  let image = @image.decode_bmp(data)
  assert_eq(image.width, width)
  assert_eq(image.height, height)
  assert_eq(@image.pixel_format_name(image.format), format)
  assert_eq(image.data, expected)
}

///|
fn bmp_regression_reject(data : Bytes) -> Unit raise {
  let rejected = try {
    let _ = @image.decode_bmp(data)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

'''
destination = Path(__file__).resolve().parents[1] / "bmp_regression_test.mbt"
destination.write_text(source + "\n".join(tests), encoding="utf-8", newline="\n")
print(f"Generated {len(tests)} BMP regressions with Pillow-verified pixel fixtures")
