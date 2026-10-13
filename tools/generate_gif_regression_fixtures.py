"""Regenerate GIF regressions: python tools/generate_gif_regression_fixtures.py.

Run moon fmt afterward. Hand-built GIF blocks and LZW codes exercise parser edge
cases. Pillow independently decodes every valid fixture and supplies exact RGBA
frames. No MoonBit output is used to generate the expected values.
"""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
import struct

from PIL import Image, ImageSequence


PALETTE = [(13, 29, 41), (223, 17, 31), (19, 211, 47), (23, 37, 229)]


def subblocks(data: bytes, block_size: int = 255) -> bytes:
    return b"".join(bytes([len(data[offset:offset + block_size])])
                    + data[offset:offset + block_size]
                    for offset in range(0, len(data), block_size)) + b"\0"


def codes(values: list[int], minimum: int = 2) -> bytes:
    """Pack explicit LZW codes, tracking decoder-side code width independently."""
    clear = 1 << minimum
    end = clear + 1
    size = minimum + 1
    next_code = end + 1
    previous = False
    bits = []
    for value in values:
        bits.extend((value >> bit) & 1 for bit in range(size))
        if value == clear:
            size, next_code, previous = minimum + 1, end + 1, False
        elif value != end:
            if previous and next_code < 4096:
                next_code += 1
                if next_code == 1 << size and size < 12:
                    size += 1
            previous = True
    bits.extend([0] * (-len(bits) % 8))
    return bytes(sum(bits[offset + bit] << bit for bit in range(8))
                 for offset in range(0, len(bits), 8))


def literal_data(pixels: list[int], minimum: int = 2) -> bytes:
    clear = 1 << minimum
    return codes([value for pixel in pixels for value in (clear, pixel)]
                 + [clear + 1], minimum)


def table(palette: list[tuple[int, int, int]]) -> bytes:
    return bytes(channel for color in palette for channel in color)


def header(width: int, height: int, palette=PALETTE, background: int = 0) -> bytes:
    packed = 0x80 | (len(palette).bit_length() - 2) if palette else 0
    return b"GIF89a" + struct.pack("<HHBBB", width, height, packed, background, 0) + table(palette)


def frame(width: int, height: int, pixels: list[int], left: int = 0, top: int = 0,
          palette=None, interlaced: bool = False, minimum: int = 2,
          compressed: bytes | None = None, block_size: int = 255) -> bytes:
    packed = 0x80 | (len(palette).bit_length() - 2) if palette else 0
    if interlaced:
        packed |= 0x40
        order = list(range(0, height, 8)) + list(range(4, height, 8))
        order += list(range(2, height, 4)) + list(range(1, height, 2))
        pixels = [pixel for row in order for pixel in pixels[row * width:(row + 1) * width]]
    compressed = literal_data(pixels, minimum) if compressed is None else compressed
    return (b"," + struct.pack("<HHHHB", left, top, width, height, packed)
            + (table(palette) if palette else b"") + bytes([minimum])
            + subblocks(compressed, block_size))


def gce(disposal: int = 0, delay: int = 0, transparent: int | None = None) -> bytes:
    return b"!\xf9\x04" + bytes([(disposal << 2) | int(transparent is not None)]) + struct.pack(
        "<HB", delay, transparent or 0) + b"\0"


def literal(data: bytes, indent: str = "    ") -> str:
    return "[\n" + "\n".join(indent + ", ".join(str(value) for value in data[offset:offset + 16]) + ","
                            for offset in range(0, len(data), 16)) + "\n  ]"


def success_test(name: str, data: bytes, expected_frames: list[bytes] | None = None) -> str:
    image = Image.open(BytesIO(data))
    size = image.size
    loop = image.info.get("loop", 0)
    frames = []
    delays = []
    for current in ImageSequence.Iterator(image):
        frames.append(current.convert("RGBA").tobytes())
        delays.append(current.info.get("duration", 0) // 10)
    if expected_frames is not None:
        frames = expected_frames
    output = (f'///|\ntest "gif_regression_{name}" {{\n'
              f"  let data = gif_regression_bytes({literal(data)})\n"
              f"  let animation = @image.decode_gif_all(data)\n"
              f"  if animation.width != {size[0]} || animation.height != {size[1]} ||\n"
              f"    animation.frames.length() != {len(frames)} || animation.loop_count != {loop} {{\n"
              '    raise Failure::Failure("GIF animation metadata mismatch")\n  }\n')
    for index, (pixels, delay) in enumerate(zip(frames, delays)):
        output += (f"  let expected = gif_regression_bytes({literal(pixels)})\n"
                   f"  gif_regression_check(animation.frames[{index}], {size[0]}, {size[1]}, expected)\n"
                   f"  if animation.delays[{index}] != {delay} {{\n"
                   f'    raise Failure::Failure("GIF delay mismatch in frame {index}")\n  }}\n')
        if index == 0:
            output += f"  gif_regression_check(@image.decode_gif(data), {size[0]}, {size[1]}, expected)\n"
    return output + "}\n"


def invalid_test(name: str, data: bytes, all_only: bool = False) -> str:
    return (f'///|\ntest "gif_regression_reject_{name}" {{\n'
            f"  let data = gif_regression_bytes({literal(data)})\n"
            f"  gif_regression_reject(data, all_only={str(all_only).lower()})\n}}\n")


def main() -> None:
    valid = {}
    valid["offset_first_frame"] = header(4, 3) + frame(2, 1, [1, 2], 1, 1) + b";"
    valid["local_palette_offset"] = (header(4, 3) + frame(2, 1, [0, 1], 1, 1,
                                                     palette=[PALETTE[0], (73, 149, 229)]) + b";")
    valid["transparent_offset"] = header(4, 3) + gce(transparent=0) + frame(2, 1, [1, 0], 1, 1) + b";"
    valid["repeated_clear_codes"] = header(2, 1) + frame(2, 1, [], compressed=codes([4, 4, 0, 4, 4, 1, 5])) + b";"
    # The unused remainder of the final byte need not be zero-valued.
    padded = bytearray(literal_data([1]))
    padded[-1] |= 0xFE
    valid["nonzero_lzw_bit_padding"] = header(1, 1) + frame(1, 1, [], compressed=bytes(padded)) + b";"
    valid["kwkwk_code_size_growth"] = header(6, 1) + frame(6, 1, [], compressed=codes([4, 0, 6, 7, 5])) + b";"
    roots = [index % 4 for index in range(4300)]
    for reset in (False, True):
        values = [4] + roots + ([4, 4, 2] if reset else []) + [5]
        width = len(roots) + int(reset)
        valid[f"full_dictionary_{'reset' if reset else 'deferred_clear'}"] = (
            header(width, 1) + frame(width, 1, [], compressed=codes(values)) + b";")
    valid["subblock_byte_boundaries"] = header(11, 3) + frame(11, 3, [i % 4 for i in range(33)], block_size=1) + b";"
    valid["lzw_minimum_8"] = header(3, 2) + frame(3, 2, [1, 2, 3, 0, 2, 1], minimum=8) + b";"
    for height in (1, 2, 3, 5, 9):
        pixels = [(x + y * 3) % 4 for y in range(height) for x in range(3)]
        valid[f"interlace_height_{height}"] = header(5, height + 2) + frame(3, height, pixels, 1, 1, interlaced=True) + b";"
    # Disposal applies after its frame and restores only that descriptor area.
    for disposal in (1, 2, 3):
        valid[f"animation_disposal_{disposal}"] = (header(4, 2) + gce(delay=7)
            + frame(4, 2, [1] * 8) + gce(disposal, 13) + frame(2, 1, [2, 2], 1, 0)
            + gce(delay=3) + frame(1, 1, [3], 3, 1) + b";")
    valid["animation_transparent_disposal"] = (header(4, 2) + gce(1, 4, 0)
        + frame(4, 2, [1, 0, 0, 1, 1, 1, 0, 0]) + gce(2, 5, 0)
        + frame(2, 1, [2, 0], 1, 0) + gce(1, 6, 0) + frame(1, 1, [3], 3, 1) + b";")
    valid["animation_control_scope"] = (header(3, 1) + gce(1, 9, 0)
        + frame(3, 1, [1, 0, 1]) + frame(1, 1, [0], 1, 0) + b";")
    valid["netscape_finite_loop"] = (header(2, 1) + b"!\xff\x0bNETSCAPE2.0\x03\x01\x05\x00\x00"
        + gce(1, 12) + frame(2, 1, [1, 2]) + b";")
    valid["unknown_extension_and_comment"] = (header(2, 1) + b"!\xfe" + subblocks(b"Comment", 2)
        + b"!\xCE" + subblocks(b"Unknown") + frame(2, 1, [1, 2]) + b";")

    # Pillow's encoder exercises normal compression, overlapping strings and
    # variable-width dictionaries on deterministic source pixels.
    for name, width, height, pixels in [
        ("pillow_dictionary_growth", 131, 37, [(i * 71 + i // 17) % 256 for i in range(131 * 37)]),
        ("pillow_long_runs", 97, 41, [(i // 211) % 4 for i in range(97 * 41)]),
    ]:
        image = Image.new("P", (width, height))
        image.putpalette([channel for index in range(256)
                          for channel in ((index * 73) % 256, (index * 113) % 256, (index * 179) % 256)])
        image.putdata(pixels)
        output = BytesIO()
        image.save(output, format="GIF", optimize=False, interlace=True)
        valid[name] = output.getvalue()

    invalid = {}
    small_header = header(2, 1)
    for name, payload, width in [
        ("early_end_code", codes([4, 0, 5]), 2),
        ("missing_end_code", codes([4, 0]), 1),
        ("invalid_first_code", codes([4, 6, 5]), 1),
        ("invalid_forward_code", codes([4, 0, 7, 5]), 2),
        ("excess_pixels", codes([4, 0, 1, 5]), 1),
        ("empty_image_data", b"", 1),
    ]:
        invalid[name] = small_header + frame(width, 1, [], compressed=payload) + b";"
    for minimum in (0, 1, 9, 12, 255):
        invalid[f"code_size_{minimum}"] = small_header + frame(1, 1, [], minimum=minimum, compressed=b"\0") + b";"
    invalid["missing_palette"] = header(2, 1, []) + frame(2, 1, [0, 1]) + b";"
    invalid["palette_index"] = header(1, 1, PALETTE[:2]) + frame(1, 1, [3]) + b";"
    invalid["zero_canvas_width"] = header(0, 1) + b";"
    invalid["oversize_canvas"] = header(65535, 65535) + b";"
    invalid["zero_frame_width"] = small_header + frame(0, 1, []) + b";"
    invalid["oversize_frame"] = small_header + frame(65535, 65535, []) + b";"
    invalid["frame_outside_canvas"] = small_header + frame(2, 1, [0, 1], left=1) + b";"
    invalid["truncated_global_palette"] = header(1, 1)[:17]
    invalid["truncated_local_palette"] = header(1, 1) + frame(1, 1, [0], palette=PALETTE)[:14]
    invalid["truncated_descriptor"] = small_header + b",\0\0"
    invalid["truncated_gce"] = small_header + gce()[:-1]
    invalid["gce_wrong_size"] = small_header + b"!\xf9\x03\0\0\0\0\0" + frame(1, 1, [0]) + b";"
    invalid["gce_wrong_terminator"] = small_header + gce()[:-1] + b"\x01" + frame(1, 1, [0]) + b";"
    invalid["unterminated_subblocks"] = small_header + frame(2, 1, [0, 1])[:-1]
    invalid["truncated_subblock"] = small_header + b",\0\0\0\0\x02\0\x01\0\0\x02\x05\0"
    invalid["unterminated_comment"] = small_header + b"!\xfe\x03abc"
    invalid["truncated_application"] = small_header + b"!\xff\x0bNETSCAPE"
    invalid["excess_lzw_data"] = small_header + frame(1, 1, [], compressed=literal_data([0]) + b"\0") + b";"
    # Plain text is a rendering block. Skipping it would silently lose content.
    text_header = struct.pack("<HHHHBBBB", 0, 0, 2, 1, 1, 1, 1, 0)
    invalid["unsupported_plain_text"] = small_header + b"!\x01\x0c" + text_header + subblocks(b"A") + frame(2, 1, [0, 1]) + b";"

    source = '''// Regenerate: python tools/generate_gif_regression_fixtures.py, then moon fmt.
// Expected RGBA pixels and metadata are independently decoded by Pillow.

///|
fn gif_regression_bytes(values : Array[Int]) -> Bytes {
  Bytes::from_array(values.map(value => value.to_byte()))
}

///|
fn gif_regression_check(image : @image.Image, width : Int, height : Int, expected : Bytes) -> Unit raise Failure {
  if image.width != width || image.height != height || @image.pixel_format_name(image.format) != "RGBA8" {
    raise Failure::Failure("GIF image dimensions or format mismatch")
  }
  if image.data.length() != expected.length() {
    raise Failure::Failure("GIF byte count mismatch")
  }
  for i = 0; i < expected.length(); i = i + 1 {
    if image.data[i] != expected[i] {
      raise Failure::Failure("GIF byte \\{i}: expected \\{expected[i].to_int()}, got \\{image.data[i].to_int()}")
    }
  }
}

///|
fn gif_regression_reject(data : Bytes, all_only? : Bool = false) -> Unit raise Failure {
  if !all_only {
    let rejected = try { let _ = @image.decode_gif(data); false } catch { _ => true }
    if !rejected { raise Failure::Failure("GIF first-frame decoder accepted malformed input") }
  }
  let rejected = try { let _ = @image.decode_gif_all(data); false } catch { _ => true }
  if !rejected { raise Failure::Failure("GIF animation decoder accepted malformed input") }
}

'''
    source += "\n".join(success_test(name, data) for name, data in valid.items())
    # GIF89a section 18: uncovered pixels use the logical background index.
    # Pillow instead initializes these pixels with palette index zero.
    data = header(3, 1, background=2) + frame(1, 1, [3], left=1) + b";"
    expected = bytes([*PALETTE[2], 255, *PALETTE[3], 255, *PALETTE[2], 255])
    source += "\n// GIF89a background rule; Pillow differs for partial first frames.\n"
    source += success_test("logical_background_index", data, [expected])
    source += "\n".join(invalid_test(name, data) for name, data in invalid.items())
    source += invalid_test("missing_animation_trailer", small_header + frame(2, 1, [0, 1]), all_only=True)
    # Every strict prefix before a complete first image must fail through both APIs.
    truncation_fixture = header(2, 1) + gce(transparent=0) + frame(2, 1, [0, 1], palette=PALETTE) + b";"
    source += (f'\n///|\ntest "gif_regression_all_first_frame_truncations" {{\n'
               f"  let data = gif_regression_bytes({literal(truncation_fixture)})\n"
               "  for length = 0; length < data.length() - 1; length = length + 1 {\n"
               "    gif_regression_reject(data[:length].to_owned())\n  }\n}\n")
    path = Path(__file__).resolve().parents[1] / "gif_regression_test.mbt"
    path.write_text(source, encoding="utf-8", newline="\n")
    print(f"Generated {len(valid)} valid Pillow-verified GIF cases, 1 spec background case, "
          f"{len(invalid) + 1} malformed cases and exhaustive truncations")


if __name__ == "__main__":
    main()
