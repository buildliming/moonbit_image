"""Regenerate DEFLATE regression tests; verify fixtures with Python's zlib.

Run from the repository root: python tools/generate_png_deflate_fixtures.py
No third-party packages are required.
"""

from pathlib import Path
import zlib


class Bits:
    def __init__(self):
        self.bits = []

    def value(self, value, width):
        self.bits.extend((value >> bit) & 1 for bit in range(width))

    def code(self, value, width):
        self.bits.extend((value >> bit) & 1 for bit in reversed(range(width)))

    def fixed(self, symbol):
        if symbol <= 143:
            self.code(symbol + 48, 8)
        elif symbol <= 255:
            self.code(symbol - 144 + 400, 9)
        elif symbol <= 279:
            self.code(symbol - 256, 7)
        else:
            self.code(symbol - 280 + 192, 8)

    def block(self, final, kind):
        self.value(final, 1)
        self.value(kind, 2)

    def align(self):
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        self.align()
        return bytes(
            sum(self.bits[offset + bit] << bit for bit in range(8))
            for offset in range(0, len(self.bits), 8)
        )


def dynamic_header(bits, distance_count=1, final=1):
    bits.block(final, 2)
    bits.value(0, 5)  # 257 literal/length codes
    bits.value(distance_count - 1, 5)
    bits.value(14, 4)  # 18 code-length codes
    order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1]
    for symbol in order:
        bits.value({0: 2, 1: 2, 2: 2, 18: 2}.get(symbol, 0), 3)


def code_lengths(bits, lengths):
    offset = 0
    while offset < len(lengths):
        if lengths[offset] != 0:
            bits.code(lengths[offset], 2)
            offset += 1
            continue
        count = 0
        while offset + count < len(lengths) and lengths[offset + count] == 0:
            count += 1
        if count >= 11:
            count = min(count, 138)
            bits.code(3, 2)
            bits.value(count - 11, 7)
        else:
            count = 1
            bits.code(0, 2)
        offset += count


valid = {}
invalid = {}

bits = Bits()
bits.block(0, 1)
bits.fixed(65)
bits.fixed(256)
bits.block(1, 1)
bits.fixed(66)
bits.fixed(256)
valid["fixed_blocks_keep_lookahead"] = (bits.bytes(), b"AB")

bits = Bits()
bits.block(0, 1)
bits.fixed(65)
bits.fixed(256)
bits.block(1, 0)
bits.align()
for value in b"\x02\x00\xfd\xffBC":
    bits.value(value, 8)
valid["fixed_then_stored_block"] = (bits.bytes(), b"ABC")

bits = Bits()
bits.block(0, 1)
bits.fixed(65)
bits.fixed(66)
bits.fixed(256)
bits.block(1, 1)
bits.fixed(261)  # seven-byte match, distance two, crossing the block boundary
bits.code(1, 5)
bits.fixed(256)
valid["back_reference_crosses_blocks"] = (bits.bytes(), b"ABABABABA")

bits = Bits()
bits.block(0, 1)
bits.fixed(66)
bits.fixed(256)
dynamic_header(bits)
code_lengths(bits, [0] * 65 + [1] + [0] * 190 + [1, 0])
bits.code(0, 1)
bits.code(1, 1)
valid["fixed_then_dynamic_block"] = (bits.bytes(), b"BA")

for kind in [0, 1]:
    bits = Bits()
    dynamic_header(bits, final=0)
    code_lengths(bits, [0] * 65 + [2, 2] + [0] * 189 + [1, 0])
    bits.code(2, 2)  # literal A; EOB has a shorter one-bit code
    bits.code(0, 1)  # two-bit lookup prefetches the next block's first bit
    bits.block(1, kind)
    if kind == 0:
        bits.align()
        for value in b"\x01\x00\xfe\xffB":
            bits.value(value, 8)
    else:
        bits.fixed(66)
        bits.fixed(256)
    suffix = "stored" if kind == 0 else "fixed"
    valid[f"dynamic_then_{suffix}_block"] = (bits.bytes(), b"AB")

bits = Bits()
dynamic_header(bits)
code_lengths(bits, [0] * 65 + [1] + [0] * 190 + [1, 0])
bits.code(0, 1)  # literal A
bits.code(1, 1)  # EOB
valid["dynamic_empty_distance_tree"] = (bits.bytes(), b"A")

bits = Bits()
dynamic_header(bits)
code_lengths(bits, [0] * 256 + [1, 0])
bits.code(0, 1)  # sole EOB symbol
valid["dynamic_single_end_code"] = (bits.bytes(), b"")

for name, lengths in [
    ("empty_code_tree", [0, 0, 0, 0]),
    ("oversubscribed_code_tree", [1, 1, 1, 0]),
    ("incomplete_code_tree", [2, 0, 0, 0]),
]:
    bits = Bits()
    bits.block(1, 2)
    bits.value(0, 14)
    for length in lengths:
        bits.value(length, 3)
    invalid[name] = bits.bytes()

bits = Bits()
bits.block(1, 2)
bits.value(0, 14)
for length in [1, 0, 0, 1]:
    bits.value(length, 3)
bits.code(1, 1)  # repeat 16 without a previous length
bits.value(0, 2)
invalid["repeat_without_previous"] = bits.bytes()

bits = Bits()
dynamic_header(bits)
for _ in range(2):
    bits.code(3, 2)
    bits.value(127, 7)  # 138 zeros each: exceeds 258 code lengths
invalid["repeat_exceeds_code_lengths"] = bits.bytes()

bits = Bits()
dynamic_header(bits)
code_lengths(bits, [0] * 65 + [1] + [0] * 191 + [1])
invalid["missing_end_code"] = bits.bytes()

bits = Bits()
dynamic_header(bits)
code_lengths(bits, [0] * 65 + [1, 1] + [0] * 189 + [1, 0])
invalid["oversubscribed_literal_tree"] = bits.bytes()

bits = Bits()
dynamic_header(bits)
code_lengths(bits, [0] * 65 + [2] + [0] * 190 + [2, 0])
invalid["incomplete_literal_tree"] = bits.bytes()

bits = Bits()
dynamic_header(bits, distance_count=3)
code_lengths(bits, [0] * 65 + [1] + [0] * 190 + [1, 1, 1, 1])
invalid["oversubscribed_distance_tree"] = bits.bytes()

invalid["truncated_empty_fixed_block"] = b"\x03"
invalid["truncated_dynamic_header"] = b"\x05"
bits = Bits()
bits.block(1, 1)
bits.fixed(65)
invalid["missing_end_of_block"] = bits.bytes()

bits = Bits()
bits.block(1, 1)
bits.fixed(144)
bits.fixed(282)  # needs five length extra bits; only four padding bits remain
invalid["truncated_length_extra"] = bits.bytes()

bits = Bits()
bits.block(1, 1)
bits.fixed(65)
bits.fixed(257)
bits.code(29, 5)  # needs thirteen distance extra bits
invalid["truncated_distance_extra"] = bits.bytes()

for name, (data, expected) in valid.items():
    assert zlib.decompress(data, -15) == expected, name
for name, data in invalid.items():
    try:
        zlib.decompress(data, -15)
    except zlib.error:
        pass
    else:
        raise AssertionError(f"zlib accepted invalid fixture {name}")


def mb_bytes(data):
    return "deflate_test_bytes([" + ", ".join(f"0x{v:02X}" for v in data) + "])"


source = """// Generated by tools/generate_png_deflate_fixtures.py.
// RFC bitstreams are independently checked with Python's zlib.

///|
fn deflate_test_bytes(values : Array[Int]) -> Bytes {
  Bytes::from_array(values.map(fn(value) { value.to_byte() }))
}

///|
fn deflate_test_decompress(data : Bytes) -> Bytes raise Failure {
  let (result, _) = deflate_decompress_stream(data, 0x7FFFFFFF, 32768)
  result
}

///|
fn expect_invalid_deflate(data : Bytes) -> Unit raise Failure {
  let rejected = try {
    let _ = deflate_test_decompress(data)
    false
  } catch {
    _ => true
  }
  if !rejected {
    raise Failure::Failure("DEFLATE accepted malformed stream")
  }
}

///|
fn expect_invalid_zlib(data : Bytes, max_output? : Int = 0x7FFFFFFF) -> Unit raise Failure {
  let rejected = try {
    let _ = zlib_decompress(data, max_output~)
    false
  } catch {
    _ => true
  }
  if !rejected {
    raise Failure::Failure("zlib accepted malformed stream or exceeded output limit")
  }
}
"""
for name, (data, expected) in valid.items():
    wrapped = b"\x78\x01" + data + zlib.adler32(expected).to_bytes(4, "big")
    assert zlib.decompress(wrapped) == expected, name
    source += f"""
///|
test "png_deflate_{name}" {{
  if deflate_test_decompress({mb_bytes(data)}) != {mb_bytes(expected)} {{
    raise Failure::Failure("Incorrect DEFLATE output")
  }}
  if zlib_decompress({mb_bytes(wrapped)}) != {mb_bytes(expected)} {{
    raise Failure::Failure("Incorrect zlib output")
  }}
}}
"""
for name, data in invalid.items():
    source += f"""
///|
test "png_deflate_reject_{name}" {{
  expect_invalid_deflate({mb_bytes(data)})
}}
"""

compressed = zlib.compress(b"A" * 1024)
stored = zlib.compress(b"ABC", level=0)
literal = zlib.compress(b"ABC")
invalid_window = bytearray(zlib.compress(b""))
invalid_window[0] = 0x88
invalid_window[1] = (-invalid_window[0] * 256) % 31
source += f"""
///|
test "png_zlib_reject_invalid_window" {{
  expect_invalid_zlib({mb_bytes(invalid_window)})
}}

///|
test "png_zlib_output_limit_stored_literals_and_matches" {{
  expect_invalid_zlib({mb_bytes(stored)}, max_output=2)
  expect_invalid_zlib({mb_bytes(literal)}, max_output=2)
  expect_invalid_zlib({mb_bytes(compressed)}, max_output=1023)
  if zlib_decompress({mb_bytes(compressed)}, max_output=1024).length() != 1024 {{
    raise Failure::Failure("Output limit rejected exact size")
  }}
}}

///|
test "png_zlib_trailer_follows_final_block" {{
  if zlib_decompress({mb_bytes(literal + b'padding')}) != {mb_bytes(b'ABC')} {{
    raise Failure::Failure("Incorrect output with trailing IDAT padding")
  }}
  expect_invalid_zlib({mb_bytes(literal[:-1])})
}}
"""
output = Path(__file__).resolve().parent.parent / "png_deflate_wbtest.mbt"
output.write_text(source, encoding="utf-8")
print(f"Verified {len(valid)} valid and {len(invalid)} invalid raw DEFLATE fixtures; wrote {output.name}")
