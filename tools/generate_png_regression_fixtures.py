"""Generate pixel regression tests using only independent PNG construction.

Run `python tools/generate_png_regression_fixtures.py` from the project root,
then `moon fmt` to format the generated MoonBit source. PNG chunks, sample packing, filters and
Adam7 passes are built here; expected output is computed from the source samples
before they are packed, filtered or compressed. No project decoder is involved.
"""

from __future__ import annotations

import binascii
from pathlib import Path
import struct
import zlib


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8),
         (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
COLOR_NAMES = {0: "gray", 2: "rgb", 3: "indexed", 4: "gray_alpha", 6: "rgba"}
DEPTHS = {0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8],
          4: [8, 16], 6: [8, 16]}


def chunk(kind: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF))


def pack_row(samples: list[tuple[int, ...]], depth: int) -> bytes:
    values = [value for sample in samples for value in sample]
    if depth == 16:
        return b"".join(struct.pack(">H", value) for value in values)
    if depth == 8:
        return bytes(values)
    packed = bytearray((len(values) * depth + 7) // 8)
    for index, value in enumerate(values):
        packed[index * depth // 8] |= value << (8 - depth - index * depth % 8)
    # Deliberately fill the unused low bits. Padding must never become pixels.
    if len(values) * depth % 8:
        packed[-1] |= (1 << (8 - len(values) * depth % 8)) - 1
    return bytes(packed)


def paeth(left: int, up: int, upper_left: int) -> int:
    prediction = left + up - upper_left
    distances = [abs(prediction - value) for value in (left, up, upper_left)]
    return (left, up, upper_left)[distances.index(min(distances))]


def filter_row(row: bytes, previous: bytes, bpp: int, kind: int) -> bytes:
    result = bytearray([kind])
    for index, value in enumerate(row):
        left = row[index - bpp] if index >= bpp else 0
        up = previous[index] if previous else 0
        upper_left = previous[index - bpp] if previous and index >= bpp else 0
        predictor = (0, left, up, (left + up) // 2,
                     paeth(left, up, upper_left))[kind]
        result.append((value - predictor) & 255)
    return bytes(result)


def png(samples: list[list[tuple[int, ...]]], depth: int, color: int,
        interlaced: bool, palette: list[tuple[int, int, int]] | None = None,
        transparency: bytes | None = None) -> bytes:
    height, width = len(samples), len(samples[0])
    bpp = max(1, (CHANNELS[color] * depth + 7) // 8)
    raw = bytearray()
    passes = ADAM7 if interlaced else [(0, 0, 1, 1)]
    for pass_index, (xs, ys, x_step, y_step) in enumerate(passes):
        if xs >= width or ys >= height:
            continue
        previous = b""
        for row_index, y in enumerate(range(ys, height, y_step)):
            row = pack_row([samples[y][x] for x in range(xs, width, x_step)], depth)
            raw.extend(filter_row(row, previous, bpp, (pass_index + row_index) % 5))
            previous = row
    result = b"\x89PNG\r\n\x1a\n"
    result += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth,
                                        color, 0, 0, int(interlaced)))
    if palette is not None:
        result += chunk(b"PLTE", bytes(value for entry in palette for value in entry))
    if transparency is not None:
        result += chunk(b"tRNS", transparency)
    return result + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def palette_for(depth: int) -> list[tuple[int, int, int]]:
    return [((index * 47 + 11) % 256, (index * 83 + 29) % 256,
             (index * 113 + 53) % 256) for index in range(min(1 << depth, 8))]


def samples_for(width: int, height: int, depth: int, color: int,
                palette: list[tuple[int, int, int]] | None) -> list[list[tuple[int, ...]]]:
    modulus = len(palette) if palette else 1 << depth
    return [[tuple((((y * width + x) * 37 + channel * 59 + y * 11 + 3)
                    * (257 if depth == 16 else 1)) % modulus
                   for channel in range(CHANNELS[color])) for x in range(width)]
            for y in range(height)]


def expected(samples: list[list[tuple[int, ...]]], depth: int, color: int,
             palette: list[tuple[int, int, int]] | None,
             transparency: bytes | None) -> tuple[str, bytes]:
    output = bytearray()
    maximum = (1 << depth) - 1
    key = None
    if transparency is not None and color in (0, 2):
        key = tuple(value & maximum for value in struct.unpack(
            ">" + "H" * CHANNELS[color], transparency))
    for row in samples:
        for sample in row:
            if color == 3:
                assert palette is not None
                index = sample[0]
                output.extend(palette[index])
                output.append(transparency[index] if transparency is not None
                              and index < len(transparency) else 255)
            else:
                output.extend(value >> 8 if depth == 16 else value * 255 // maximum
                              for value in sample)
                if key is not None:
                    output.append(0 if sample == key else 255)
    fmt = {0: "GrayA8" if key is not None else "Gray8",
           2: "RGBA8" if key is not None else "RGB8", 3: "RGBA8",
           4: "GrayA8", 6: "RGBA8"}[color]
    return fmt, bytes(output)


def array_literal(data: bytes, indent: str = "    ") -> str:
    return "[\n" + "\n".join(indent + ", ".join(str(value) for value in data[index:index + 16]) + ","
                            for index in range(0, len(data), 16)) + "\n  ]"


def success_test(name: str, samples: list[list[tuple[int, ...]]], depth: int,
                 color: int, interlaced: bool,
                 palette: list[tuple[int, int, int]] | None = None,
                 transparency: bytes | None = None) -> str:
    data = png(samples, depth, color, interlaced, palette, transparency)
    fmt, output = expected(samples, depth, color, palette, transparency)
    return (f'///|\ntest "png_pixels_{name}" {{\n'
            f"  let data = png_pixels_bytes({array_literal(data)})\n"
            f"  let expected = png_pixels_bytes({array_literal(output)})\n"
            f'  png_pixels_check(data, {len(samples[0])}, {len(samples)}, "{fmt}", expected)\n'
            "}\n")


def main() -> None:
    tests = []
    for color, depths in DEPTHS.items():
        for depth in depths:
            palette = palette_for(depth) if color == 3 else None
            for interlaced in (False, True):
                width, height = (9, 9) if interlaced else (5, 5)
                if not interlaced and depth < 8:
                    width = {1: 9, 2: 5, 4: 3}[depth]
                samples = samples_for(width, height, depth, color, palette)
                name = f"{COLOR_NAMES[color]}{depth}_{'adam7' if interlaced else 'plain'}"
                tests.append(success_test(name, samples, depth, color, interlaced, palette))

    # Tiny images contain empty Adam7 passes, one-pixel rows and tall/narrow passes.
    for color, depth in [(0, 1), (0, 2), (0, 4), (3, 1), (3, 2), (3, 4), (2, 8), (4, 16)]:
        palette = palette_for(depth) if color == 3 else None
        for width, height in [(1, 1), (1, 7), (7, 1), (2, 2)]:
            samples = samples_for(width, height, depth, color, palette)
            name = f"{COLOR_NAMES[color]}{depth}_adam7_{width}x{height}"
            tests.append(success_test(name, samples, depth, color, True, palette))

    # Exact key comparisons use source precision, before 16-to-8 conversion.
    # Two 16-bit samples share their high byte but only one is transparent.
    for color, depths in [(0, DEPTHS[0]), (2, DEPTHS[2])]:
        for depth in depths:
            key = tuple(([0x1234, 0x5678, 0x9ABC] if depth == 16 else
                         [1, 17, 65])[:CHANNELS[color]])
            maximum = (1 << depth) - 1
            key = tuple(value & maximum for value in key)
            different = tuple((value + 1) & maximum for value in key)
            samples = [[key, different, key], [different, key, different]]
            transparency = b"".join(struct.pack(">H", value) for value in key)
            for interlaced in (False, True):
                name = f"{COLOR_NAMES[color]}{depth}_trns_{'adam7' if interlaced else 'plain'}"
                tests.append(success_test(name, samples, depth, color, interlaced,
                                          transparency=transparency))
            if depth < 16:
                # PNG third edition: unused upper bits of tRNS samples are ignored.
                upper_bits = 0xFFFF ^ maximum
                masked = b"".join(struct.pack(">H", value | upper_bits) for value in key)
                name = f"{COLOR_NAMES[color]}{depth}_trns_unused_upper_bits"
                tests.append(success_test(name, samples, depth, color, False,
                                          transparency=masked))

    for depth in DEPTHS[3]:
        palette = palette_for(depth)
        samples = samples_for(9, 3, depth, 3, palette)
        transparency = bytes([0]) if depth == 1 else bytes([0, 96])
        for interlaced in (False, True):
            name = f"indexed{depth}_trns_partial_{'adam7' if interlaced else 'plain'}"
            tests.append(success_test(name, samples, depth, 3, interlaced,
                                      palette, transparency))
        data = png([[(1,)]], depth, 3, False, [(12, 34, 56)])
        tests.append(f'///|\ntest "png_pixels_indexed{depth}_invalid_palette_index" {{\n'
                     f"  let data = png_pixels_bytes({array_literal(data)})\n"
                     "  let rejected = try {\n"
                     "    let _ = @image.decode_png(data)\n"
                     "    false\n"
                     "  } catch {\n"
                     "    _ => true\n"
                     "  }\n"
                     "  if !rejected {\n"
                     '    raise Failure::Failure("PNG accepted an out-of-range palette index")\n'
                     "  }\n}\n")

    header = '''// Regenerate: python tools/generate_png_regression_fixtures.py, then moon fmt.
// PNG construction uses Python stdlib, and expected pixels come from unpacked samples.

///|
fn png_pixels_bytes(values : Array[Int]) -> Bytes {
  Bytes::from_array(values.map(value => value.to_byte()))
}

///|
fn png_pixels_check(
  data : Bytes,
  width : Int,
  height : Int,
  format : String,
  expected : Bytes,
) -> Unit raise Failure {
  let image = @image.decode_png(data)
  if image.width != width || image.height != height {
    raise Failure::Failure("PNG dimensions: expected \\{width}x\\{height}, got \\{image.width}x\\{image.height}")
  }
  let actual_format = @image.pixel_format_name(image.format)
  if actual_format != format {
    raise Failure::Failure("PNG format: expected \\{format}, got \\{actual_format}")
  }
  if image.data.length() != expected.length() {
    raise Failure::Failure("PNG byte count: expected \\{expected.length()}, got \\{image.data.length()}")
  }
  for index = 0; index < expected.length(); index = index + 1 {
    if image.data[index] != expected[index] {
      raise Failure::Failure("PNG byte \\{index}: expected \\{expected[index].to_int()}, got \\{image.data[index].to_int()}")
    }
  }
}

'''
    destination = Path(__file__).resolve().parents[1] / "png_pixels_test.mbt"
    destination.write_text(header + "\n".join(tests), encoding="utf-8", newline="\n")
    print(f"Generated {len(tests)} independent PNG pixel regression cases in {destination.name}")


if __name__ == "__main__":
    main()
