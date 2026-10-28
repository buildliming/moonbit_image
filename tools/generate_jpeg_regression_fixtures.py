"""Generate independent JPEG pixel and structural regression fixtures.

Requires Pillow (libjpeg-backed). Run from the repository root.
Reference pixels come only from Pillow, never from the MoonBit decoder.
"""

from io import BytesIO
from pathlib import Path
from PIL import Image, features


def encode(mode, width, height, pixels, **options):
    image = Image.new(mode, (width, height))
    image.putdata(pixels)
    output = BytesIO()
    image.save(output, "JPEG", quality=90, **options)
    data = output.getvalue()
    reference = Image.open(BytesIO(data)).convert("RGB")
    reference.load()
    return data, reference


def markers(data):
    offset = 2
    while offset < len(data):
        assert data[offset] == 255
        marker = data[offset + 1]
        length = int.from_bytes(data[offset + 2:offset + 4], "big")
        end = offset + 2 + length
        yield marker, offset, offset + 4, end
        if marker == 0xDA:
            return
        offset = end


def remove(data, target):
    for marker, begin, _, end in markers(data):
        if marker == target:
            return data[:begin] + data[end:]
    raise AssertionError(target)


def mutate(data, target, relative, value):
    for marker, _, start, _ in markers(data):
        if marker == target:
            result = bytearray(data)
            result[start + relative] = value
            return bytes(result)
    raise AssertionError(target)


def byte_expr(data):
    return "jpeg_regression_bytes([\n    " + ",\n    ".join(
        ", ".join(f"0x{v:02X}" for v in data[i:i + 16])
        for i in range(0, len(data), 16)
    ) + ",\n  ])"


valid = {}
valid["gray_asymmetric"] = encode(
    "L", 17, 9, [(x * 11 + y * 19) % 256 for y in range(9) for x in range(17)]
)
valid["gray_extreme_frequency"] = encode(
    "L", 16, 16, [255 * ((x + y) % 2) for y in range(16) for x in range(16)]
)
valid["rgb_444_asymmetric"] = encode(
    "RGB", 13, 11,
    [((x * 19 + y * 3) % 256, (x * 7 + y * 23) % 256,
      (x * 11 + y * 13) % 256) for y in range(11) for x in range(13)],
    subsampling=0,
)
for subsampling, name in [(1, "422"), (2, "420")]:
    valid[f"rgb_{name}_odd_edges"] = encode(
        "RGB", 19, 17, [(190, 70, 135)] * (19 * 17), subsampling=subsampling,
    )
    valid[f"rgb_{name}_chroma_interpolation"] = encode(
        "RGB", 19, 17,
        [((x * 17 + y * 3) % 256, (x * 9 + y * 13) % 256,
          (x * 3 + y * 21) % 256) for y in range(17) for x in range(19)],
        subsampling=subsampling,
    )
for width in [1, 3, 4]:
    valid[f"rgb_420_narrow_{width}"] = encode(
        "RGB", width, 9,
        [((x * 29 + y * 17) % 256, (x * 17 + y * 21) % 256,
          (x * 11 + y * 13) % 256) for y in range(9) for x in range(width)],
        subsampling=2,
    )
valid["gray_restart"] = encode(
    "L", 25, 9, [(x * 9 + y * 11) % 256 for y in range(9) for x in range(25)],
    restart_marker_blocks=1,
)
valid["rgb_420_restart_counts_mcus"] = encode(
    "RGB", 33, 17, [(40, 180, 110)] * (33 * 17),
    subsampling=2, restart_marker_blocks=1,
)
gray, _ = valid["gray_asymmetric"]
for sampling in [0x12, 0x22, 0x44]:
    data = mutate(gray, 0xC0, 7, sampling)
    valid[f"gray_noninterleaved_sampling_{sampling:02x}"] = (
        data, Image.open(BytesIO(data)).convert("RGB"),
    )
for marker, name in [(0xFE, "comment"), (0xE1, "application")]:
    data = gray[:-2] + bytes([255, marker, 0, 4]) + b"ok" + gray[-2:]
    valid[f"trailing_{name}_before_eoi"] = (
        data, Image.open(BytesIO(data)).convert("RGB"),
    )
filled = gray[:-2] + b"\xff\xff\xfe\x00\x04ok\xff\xff\xd9"
valid["trailing_marker_fill_bytes"] = (
    filled, Image.open(BytesIO(filled)).convert("RGB"),
)
assert b"\xff\xd0" in valid["gray_restart"][0]
assert b"\xff\xd0" in valid["rgb_420_restart_counts_mcus"][0]

base, _ = valid["gray_asymmetric"]
restart, _ = valid["gray_restart"]
invalid = {
    "missing_quantization": remove(base, 0xDB),
    "missing_huffman": remove(base, 0xC4),
    "missing_frame": remove(base, 0xC0),
    "zero_quantization": mutate(base, 0xDB, 1, 0),
    "quantization_selector": mutate(base, 0xDB, 0, 4),
    "quantization_precision": mutate(base, 0xDB, 0, 2),
    "zero_width": mutate(mutate(base, 0xC0, 3, 0), 0xC0, 4, 0),
    "zero_height": mutate(mutate(base, 0xC0, 1, 0), 0xC0, 2, 0),
    "sample_precision": mutate(base, 0xC0, 0, 12),
    "zero_sampling": mutate(base, 0xC0, 7, 0),
    "frame_quantization_selector": mutate(base, 0xC0, 8, 4),
    "scan_component": mutate(base, 0xDA, 1, 99),
    "scan_huffman_selector": mutate(base, 0xDA, 2, 0xF0),
    "spectral_selection": mutate(base, 0xDA, 3, 1),
    "successive_approximation": mutate(base, 0xDA, 5, 1),
    "huffman_class": mutate(base, 0xC4, 0, 0x20),
    "huffman_destination": mutate(base, 0xC4, 0, 4),
    "huffman_oversubscribed": mutate(base, 0xC4, 1, 3),
    "huffman_dc_category": mutate(base, 0xC4, 17, 12),
    "missing_eoi": base[:-2],
    "restart_without_interval": remove(restart, 0xDD),
    "restart_wrong_sequence": restart.replace(b"\xff\xd0", b"\xff\xd3", 1),
    "restart_missing_marker": restart.replace(b"\xff\xd0", b"", 1),
    "restart_early_marker": base[:-2] + b"\xff\xd0\xff\xd9",
    "restart_excess_segments": restart[:-2] + b"\xff\xd5\x00\xff\xd9",
    "trailing_metadata_truncated_length": base[:-2] + b"\xff\xfe\x00",
    "trailing_metadata_excess_length": base[:-2] + b"\xff\xe1\xff\xff\xff\xd9",
    "trailing_metadata_missing_eoi": base[:-2] + b"\xff\xfe\x00\x04ok",
    "trailing_metadata_second_scan": base[:-2] + b"\xff\xfe\x00\x04ok\xff\xda\x00\x02\xff\xd9",
}
for marker, _, _, end in markers(restart):
    if marker == 0xDA:
        invalid["restart_empty_segment"] = restart[:end] + b"\xff\xd0" + restart[end:]
for mode, name, options in [
    ("CMYK", "cmyk_file", {}),
    ("RGB", "rgb_adobe_file", {"keep_rgb": True}),
]:
    count = 4 if mode == "CMYK" else 3
    encoded, _ = encode(mode, 8, 8, [tuple([90] * count)] * 64, **options)
    invalid["unsupported_" + name] = encoded
color, _ = valid["rgb_444_asymmetric"]
invalid["duplicate_frame_component"] = mutate(color, 0xC0, 9, 1)
invalid["duplicate_scan_component"] = mutate(color, 0xDA, 3, 1)
invalid["unsupported_sampling_layout"] = mutate(color, 0xC0, 7, 0x41)
invalid["unsupported_multicomponent_scan"] = mutate(color, 0xDA, 0, 1)
for marker, begin, start, end in markers(base):
    if marker == 0xC4 and base[start] == 0x10:
        changed = bytearray(base)
        changed[start + 17] = 0x0B
        invalid["huffman_ac_category"] = bytes(changed)
    if marker not in {0xE0}:
        for length in [0, 1, 65535]:
            invalid[f"segment_{marker:02x}_length_{length}"] = (
                base[:begin + 2] + length.to_bytes(2, "big") + base[begin + 4:]
            )
for marker, begin, start, end in markers(base):
    if marker == 0xC0:
        invalid["duplicate_frame"] = base[:end] + base[begin:end] + base[end:]
        invalid["progressive_frame"] = base[:begin + 1] + b"\xc2" + base[begin + 2:]
    if marker == 0xDA:
        invalid["extra_entropy_byte"] = base[:-2] + b"\x00" + base[-2:]
        invalid["truncated_entropy"] = base[:end + 1] + b"\xff\xd9"
        invalid["multiscan"] = base[:-2] + base[begin:end] + b"\xff\xd9"
    if marker == 0xDB:
        invalid["short_quantization_segment"] = base[:begin + 2] + b"\x00\x04" + base[start:start + 2] + base[end:]
    if marker == 0xC4:
        invalid["short_huffman_segment"] = base[:begin + 2] + b"\x00\x03" + base[start:start + 1] + base[end:]

source = f"""// Generated by tools/generate_jpeg_regression_fixtures.py.
// Pixel oracle: Pillow {Image.__version__}, libjpeg {features.version('jpg')}.
// Grayscale/4:4:4 allow three levels for integer IDCT/color rounding.
// Subsampled fixtures cover chroma interpolation, narrow widths and odd edges.

///|
fn jpeg_regression_bytes(values : Array[Int]) -> Bytes {{
  Bytes::from_array(values.map(fn(value) {{ value.to_byte() }}))
}}

///|
fn jpeg_regression_reject(data : Bytes) -> Unit raise Failure {{
  let rejected = try {{
    let _ = @image.decode_jpeg(data)
    false
  }} catch {{
    Failure::Failure(_) => true
  }}
  if !rejected {{
    raise Failure::Failure("Malformed JPEG decoded successfully")
  }}
}}
"""
for name, (data, reference) in valid.items():
    width, height = reference.size
    expected = list(reference.tobytes())
    source += f"""
///|
test "jpeg_regression_{name}" {{
  let data = {byte_expr(data)}
  let image = @image.decode_jpeg(data)
  if image.width != {width} || image.height != {height} ||
    @image.jpeg_dimensions(data) != ({width}, {height}) {{
    raise Failure::Failure("JPEG dimensions differ from Pillow")
  }}
  let expected = {byte_expr(expected)}
  for y = 0; y < {height}; y = y + 1 {{
    for x = 0; x < {width}; x = x + 1 {{
      let pixel = image.get_pixel(x, y)
      let offset = (y * {width} + x) * 3
      let actual = [pixel.r, pixel.g, pixel.b]
      for channel = 0; channel < 3; channel = channel + 1 {{
        let difference = actual[channel] - expected[offset + channel].to_int()
        if difference < -3 || difference > 3 {{
          raise Failure::Failure(
            "JPEG differs from Pillow at (\\{{x}},\\{{y}}) channel \\{{channel}}: \\{{difference}}",
          )
        }}
      }}
    }}
  }}
}}
"""
for name, data in invalid.items():
    source += f"""
///|
test "jpeg_regression_reject_{name}" {{
  jpeg_regression_reject({byte_expr(data)})
}}
"""
source += f"""
///|
test "jpeg_regression_all_truncated_prefixes" {{
  let valid = {byte_expr(base)}
  for length = 0; length < valid.length(); length = length + 1 {{
    jpeg_regression_reject(valid[:length].to_owned())
  }}
}}

///|
test "jpeg_regression_short_header_dimensions" {{
  let cases = [b"\\xFF\\xD8\\xFF", b"\\xFF\\xD8\\xFF\\xE0", b"\\xFF\\xD8\\xFF\\xC0\\x00\\x02"]
  for data in cases {{
    let rejected = try {{
      let _ = @image.jpeg_dimensions(data)
      false
    }} catch {{
      Failure::Failure(_) => true
    }}
    if !rejected {{
      raise Failure::Failure("Truncated JPEG dimensions accepted")
    }}
  }}
}}
"""
output = Path(__file__).resolve().parent.parent / "jpeg_regression_test.mbt"
output.write_text(source, encoding="utf-8")
print(f"Wrote {len(valid)} independent pixel tests, {len(invalid)} malformed cases and prefix/header tests")
