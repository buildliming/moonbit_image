// PNG container validation regressions. Fixtures use stored DEFLATE blocks so
// malformed PNG structure is tested independently of Huffman decoding.
// Requirements: https://www.w3.org/TR/png-3/#11Chunks

///|
fn png_validation_bytes(values : Array[Int]) -> Bytes {
  Bytes::from_array(values.map(fn(value) { value.to_byte() }))
}

///|
fn png_validation_u32(out : Buffer, value : Int) -> Unit {
  out.write_byte(((value >> 24) & 255).to_byte())
  out.write_byte(((value >> 16) & 255).to_byte())
  out.write_byte(((value >> 8) & 255).to_byte())
  out.write_byte((value & 255).to_byte())
}

///|
fn png_validation_join(parts : Array[Bytes]) -> Bytes {
  let out = Buffer()
  for part in parts {
    out.write_bytes(part)
  }
  out.to_bytes()
}

///|
fn png_validation_chunk(kind : Bytes, payload : Bytes) -> Bytes {
  let out = Buffer()
  png_validation_u32(out, payload.length())
  out.write_bytes(kind)
  out.write_bytes(payload)
  let mut crc = -1
  for part in [kind, payload] {
    for byte in part {
      crc = crc ^ byte.to_int()
      for bit = 0; bit < 8; bit = bit + 1 {
        let next = (crc >> 1) & 0x7FFFFFFF
        crc = if (crc & 1) == 0 { next } else { next ^ 0xEDB88320 }
      }
    }
  }
  png_validation_u32(out, crc ^ -1)
  out.to_bytes()
}

///|
fn png_validation_header(
  width : Int,
  height : Int,
  depth : Int,
  color : Int,
  compression? : Int = 0,
  filter? : Int = 0,
  interlace? : Int = 0,
) -> Bytes {
  let out = Buffer()
  png_validation_u32(out, width)
  png_validation_u32(out, height)
  out.write_bytes(
    png_validation_bytes([depth, color, compression, filter, interlace]),
  )
  png_validation_chunk(b"IHDR", out.to_bytes())
}

///|
fn png_validation_zlib(raw : Bytes) -> Bytes {
  let out = Buffer()
  out.write_bytes(b"\x78\x01\x01")
  let length = raw.length()
  out.write_bytes(
    png_validation_bytes([
      length & 255,
      length >> 8,
      (length ^ 65535) & 255,
      (length ^ 65535) >> 8,
    ]),
  )
  out.write_bytes(raw)
  let mut a = 1
  let mut b = 0
  for byte in raw {
    a = (a + byte.to_int()) % 65521
    b = (b + a) % 65521
  }
  png_validation_u32(out, (b << 16) | a)
  out.to_bytes()
}

///|
fn png_validation_idat(raw : Bytes) -> Bytes {
  png_validation_chunk(b"IDAT", png_validation_zlib(raw))
}

///|
fn png_validation_png(chunks : Array[Bytes]) -> Bytes {
  png_validation_join([b"\x89PNG\r\n\x1A\n", png_validation_join(chunks)])
}

///|
fn png_validation_reject(data : Bytes, description : String) -> Unit raise {
  let rejected = try {
    let _ = @image.decode_png(data)
    false
  } catch {
    _ => true
  }
  if !rejected {
    fail("PNG accepted invalid input: \{description}")
  }
}

///|
fn png_validation_corrupt_crc(chunk : Bytes) -> Bytes {
  let out = Buffer()
  out.write_bytes(chunk[:chunk.length() - 1])
  out.write_byte((chunk[chunk.length() - 1].to_int() ^ 1).to_byte())
  out.to_bytes()
}

///|
test "png_validation_valid_stored_stream_and_split_idat" {
  let stream = png_validation_zlib(b"\x00\x5A")
  for split = 0; split <= stream.length(); split = split + 1 {
    let image = @image.decode_png(
      png_validation_png([
        png_validation_header(1, 1, 8, 0),
        png_validation_chunk(b"IDAT", b""),
        png_validation_chunk(b"IDAT", stream[:split].to_owned()),
        png_validation_chunk(b"IDAT", stream[split:].to_owned()),
        png_validation_chunk(b"IDAT", b""),
        png_validation_chunk(b"IEND", b""),
      ]),
    )
    assert_eq(image.width, 1)
    assert_eq(image.height, 1)
    assert_eq(image.get_pixel(0, 0).r, 90)
  }
}

///|
test "png_validation_unknown_ancillary_chunk_is_skipped" {
  let image = @image.decode_png(
    png_validation_png([
      png_validation_header(1, 1, 8, 0),
      png_validation_chunk(b"vpAg", b"unknown ancillary payload"),
      png_validation_idat(b"\x00\x5A"),
      png_validation_chunk(b"vpAg", b"after IDAT"),
      png_validation_chunk(b"IEND", b""),
    ]),
  )
  assert_eq(image.get_pixel(0, 0).r, 90)
}

///|
test "png_validation_bad_and_truncated_signature" {
  let signature = b"\x89PNG\r\n\x1A\n"
  for length = 0; length < 8; length = length + 1 {
    png_validation_reject(signature[:length].to_owned(), "short signature")
  }
  png_validation_reject(b"\x89PNG\r\n\x1A\x00", "bad signature byte")
}

///|
test "png_validation_ihdr_must_be_first_and_unique" {
  let header = png_validation_header(1, 1, 8, 0)
  let image_data = png_validation_idat(b"\x00\x5A")
  let end = png_validation_chunk(b"IEND", b"")
  for
    chunks in [
      [image_data, end],
      [png_validation_chunk(b"vpAg", b""), header, image_data, end],
      [header, header, image_data, end],
    ] {
    png_validation_reject(png_validation_png(chunks), "IHDR order or duplicate")
  }
}

///|
test "png_validation_bad_ihdr_length_and_methods" {
  let end = png_validation_chunk(b"IEND", b"")
  let image_data = png_validation_idat(b"\x00\x5A")
  for
    header in [
      png_validation_chunk(b"IHDR", b""),
      png_validation_chunk(
        b"IHDR", b"\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00",
      ),
      png_validation_header(1, 1, 8, 0, compression=1),
      png_validation_header(1, 1, 8, 0, filter=1),
      png_validation_header(1, 1, 8, 0, interlace=2),
      png_validation_header(1, 1, 4, 2),
      png_validation_header(1, 1, 16, 3),
      png_validation_header(1, 1, 8, 1),
    ] {
    png_validation_reject(
      png_validation_png([header, image_data, end]),
      "bad IHDR",
    )
  }
}

///|
test "png_validation_invalid_and_overflowing_dimensions" {
  for
    (width, height) in [
      (0, 1),
      (1, 0),
      (-2147483648, 1),
      (1, -2147483648),
      (2147483647, 1),
      (2147483647, 2147483647),
      (65536, 65536),
    ] {
    png_validation_reject(
      png_validation_png([
        png_validation_header(width, height, 8, 6),
        png_validation_idat(b"\x00\x00\x00\x00\x00"),
        png_validation_chunk(b"IEND", b""),
      ]),
      "invalid dimensions or overflowing image byte count",
    )
  }
}

///|
test "png_validation_truncated_chunk_and_oversized_length" {
  let valid = png_validation_png([
    png_validation_header(1, 1, 8, 0),
    png_validation_idat(b"\x00\x5A"),
    png_validation_chunk(b"IEND", b""),
  ])
  for length = 8; length < valid.length(); length = length + 1 {
    png_validation_reject(valid[:length].to_owned(), "truncated PNG chunk")
  }
  for
    prefix in [
      b"\x7F\xFF\xFF\xFFIDAT", b"\x80\x00\x00\x00IDAT", b"\xFF\xFF\xFF\xFFIDAT",
    ] {
    png_validation_reject(
      png_validation_png([png_validation_header(1, 1, 8, 0), prefix]),
      "out-of-range chunk length",
    )
  }
}

///|
test "png_validation_checks_all_critical_chunk_crcs" {
  let chunks = [
    png_validation_header(1, 1, 8, 3),
    png_validation_chunk(b"PLTE", b"\x10\x20\x30"),
    png_validation_idat(b"\x00\x00"),
    png_validation_chunk(b"IEND", b""),
  ]
  for bad = 0; bad < chunks.length(); bad = bad + 1 {
    let corrupted = chunks.copy()
    corrupted[bad] = png_validation_corrupt_crc(chunks[bad])
    png_validation_reject(png_validation_png(corrupted), "critical chunk CRC")
  }
}

///|
test "png_validation_unknown_critical_chunk" {
  png_validation_reject(
    png_validation_png([
      png_validation_header(1, 1, 8, 0),
      png_validation_chunk(b"VpAg", b""),
      png_validation_idat(b"\x00\x5A"),
      png_validation_chunk(b"IEND", b""),
    ]),
    "unknown critical chunk",
  )
}

///|
test "png_validation_requires_idat_and_empty_iend" {
  let header = png_validation_header(1, 1, 8, 0)
  let image_data = png_validation_idat(b"\x00\x5A")
  for
    chunks in [
      [header, image_data],
      [header, png_validation_chunk(b"IEND", b"")],
      [header, image_data, png_validation_chunk(b"IEND", b"\x00")],
    ] {
    png_validation_reject(
      png_validation_png(chunks),
      "missing IDAT/IEND or nonempty IEND",
    )
  }
}

///|
test "png_validation_idat_chunks_must_be_consecutive" {
  let stream = png_validation_zlib(b"\x00\x5A")
  png_validation_reject(
    png_validation_png([
      png_validation_header(1, 1, 8, 0),
      png_validation_chunk(b"IDAT", stream[:3].to_owned()),
      png_validation_chunk(b"vpAg", b""),
      png_validation_chunk(b"IDAT", stream[3:].to_owned()),
      png_validation_chunk(b"IEND", b""),
    ]),
    "nonconsecutive IDAT chunks",
  )
}

///|
test "png_validation_scanline_length_and_filter" {
  for interlace in [0, 1] {
    for raw in [b"", b"\x00", b"\x00\x5A\x00", b"\x05\x5A", b"\xFF\x5A"] {
      png_validation_reject(
        png_validation_png([
          png_validation_header(1, 1, 8, 0, interlace~),
          png_validation_idat(raw),
          png_validation_chunk(b"IEND", b""),
        ]),
        "bad scanline length or filter",
      )
    }
  }
}

///|
test "png_validation_indexed_palette_size_and_presence" {
  let header = png_validation_header(1, 1, 1, 3)
  let image_data = png_validation_idat(b"\x00\x00")
  let end = png_validation_chunk(b"IEND", b"")
  png_validation_reject(
    png_validation_png([header, image_data, end]),
    "missing PLTE",
  )
  for
    palette in [
      b"",
      b"\x10",
      b"\x10\x20",
      b"\x10\x20\x30\x40\x50\x60\x70\x80\x90",
      Bytes::from_array(Array::make(257 * 3, b'\x00')),
    ] {
    png_validation_reject(
      png_validation_png([
        header,
        png_validation_chunk(b"PLTE", palette),
        image_data,
        end,
      ]),
      "invalid PLTE size",
    )
  }
}

///|
test "png_validation_palette_order_and_duplicates" {
  let header = png_validation_header(1, 1, 8, 3)
  let palette = png_validation_chunk(b"PLTE", b"\x10\x20\x30")
  let image_data = png_validation_idat(b"\x00\x00")
  let end = png_validation_chunk(b"IEND", b"")
  for
    chunks in [
      [palette, header, image_data, end],
      [header, palette, palette, image_data, end],
      [header, image_data, palette, end],
    ] {
    png_validation_reject(png_validation_png(chunks), "PLTE order or duplicate")
  }
}

///|
test "png_validation_palette_forbidden_for_grayscale" {
  for color in [0, 4] {
    png_validation_reject(
      png_validation_png([
        png_validation_header(1, 1, 8, color),
        png_validation_chunk(b"PLTE", b"\x10\x20\x30"),
        png_validation_idat(
          if color == 0 {
            b"\x00\x5A"
          } else {
            b"\x00\x5A\xFF"
          },
        ),
        png_validation_chunk(b"IEND", b""),
      ]),
      "PLTE forbidden for grayscale color type",
    )
  }
}

///|
test "png_validation_palette_index_must_exist" {
  for (depth, sample) in [(1, 128), (2, 64), (4, 16), (8, 1)] {
    png_validation_reject(
      png_validation_png([
        png_validation_header(1, 1, depth, 3),
        png_validation_chunk(b"PLTE", b"\x10\x20\x30"),
        png_validation_idat(png_validation_bytes([0, sample])),
        png_validation_chunk(b"IEND", b""),
      ]),
      "palette index outside actual PLTE entries",
    )
  }
}

///|
test "png_validation_transparency_lengths_and_color_types" {
  for
    (color, transparency, raw) in [
      (0, b"\x00", b"\x00\x5A"),
      (0, b"\x00\x5A\x00", b"\x00\x5A"),
      (2, b"\x00\x10\x00\x20\x00", b"\x00\x10\x20\x30"),
      (2, b"\x00\x10\x00\x20\x00\x30\x00", b"\x00\x10\x20\x30"),
      (4, b"\x00\x5A", b"\x00\x5A\xFF"),
      (6, b"\x00\x10\x00\x20\x00\x30", b"\x00\x10\x20\x30\xFF"),
    ] {
    png_validation_reject(
      png_validation_png([
        png_validation_header(1, 1, 8, color),
        png_validation_chunk(b"tRNS", transparency),
        png_validation_idat(raw),
        png_validation_chunk(b"IEND", b""),
      ]),
      "invalid tRNS length or forbidden color type",
    )
  }
  png_validation_reject(
    png_validation_png([
      png_validation_header(1, 1, 8, 3),
      png_validation_chunk(b"PLTE", b"\x10\x20\x30"),
      png_validation_chunk(b"tRNS", b"\x00\xFF"),
      png_validation_idat(b"\x00\x00"),
      png_validation_chunk(b"IEND", b""),
    ]),
    "more alpha values than palette entries",
  )
}

///|
test "png_validation_transparency_order_duplicates_and_crc" {
  let header = png_validation_header(1, 1, 8, 3)
  let palette = png_validation_chunk(b"PLTE", b"\x10\x20\x30")
  let transparency = png_validation_chunk(b"tRNS", b"\x80")
  let image_data = png_validation_idat(b"\x00\x00")
  let end = png_validation_chunk(b"IEND", b"")
  for
    chunks in [
      [header, transparency, palette, image_data, end],
      [header, palette, transparency, transparency, image_data, end],
      [header, palette, image_data, transparency, end],
      [
        header,
        palette,
        png_validation_corrupt_crc(transparency),
        image_data,
        end,
      ],
    ] {
    png_validation_reject(
      png_validation_png(chunks),
      "tRNS order, duplicate or CRC",
    )
  }
}

///|
test "png_validation_rgb_suggested_palette_before_transparency" {
  let image = @image.decode_png(
    png_validation_png([
      png_validation_header(2, 1, 8, 2),
      png_validation_chunk(b"PLTE", b"\xAA\xBB\xCC"),
      png_validation_chunk(b"tRNS", b"\x00\x10\x00\x20\x00\x30"),
      png_validation_idat(b"\x00\x10\x20\x30\x40\x50\x60"),
      png_validation_chunk(b"IEND", b""),
    ]),
  )
  let transparent = image.get_pixel(0, 0)
  assert_eq(
    (transparent.r, transparent.g, transparent.b, transparent.a),
    (16, 32, 48, 0),
  )
  let solid = image.get_pixel(1, 0)
  assert_eq((solid.r, solid.g, solid.b, solid.a), (64, 80, 96, 255))
}

///|
test "png_validation_empty_indexed_transparency_is_opaque" {
  let image = @image.decode_png(
    png_validation_png([
      png_validation_header(2, 1, 8, 3),
      png_validation_chunk(b"PLTE", b"\x10\x20\x30\x40\x50\x60"),
      png_validation_chunk(b"tRNS", b""),
      png_validation_idat(b"\x00\x00\x01"),
      png_validation_chunk(b"IEND", b""),
    ]),
  )
  let first = image.get_pixel(0, 0)
  assert_eq((first.r, first.g, first.b, first.a), (16, 32, 48, 255))
  let second = image.get_pixel(1, 0)
  assert_eq((second.r, second.g, second.b, second.a), (64, 80, 96, 255))
}

///|
test "png_validation_unused_final_idat_bytes_are_ignored" {
  for trailing in [b"\x00", b"\x00\x00\x00\x00", b"\xFF\x12\x34\x56\x78"] {
    let stream = png_validation_join([
      png_validation_zlib(b"\x00\x5A"),
      trailing,
    ])
    let image = @image.decode_png(
      png_validation_png([
        png_validation_header(1, 1, 8, 0),
        png_validation_chunk(b"IDAT", stream),
        png_validation_chunk(b"IEND", b""),
      ]),
    )
    assert_eq(image.get_pixel(0, 0).r, 90)
  }
}

///|
test "png_validation_crc_valid_small_chunk_payloads_never_panic" {
  // Reach recognized chunk handlers with a valid CRC and bounded dimensions.
  // Both decoding and Failure are allowed; a bounds panic fails the test.
  for color in [0, 2, 3, 4, 6] {
    for kind in [b"PLTE", b"tRNS", b"IDAT", b"IEND", b"vpAg", b"VpAg"] {
      for length = 0; length <= 15; length = length + 1 {
        let payload = Bytes::from_array(
          Array::makei(length, fn(index) { (index * 17 + length).to_byte() }),
        )
        let chunks = [png_validation_header(1, 1, 8, color)]
        if color == 3 {
          chunks.push(png_validation_chunk(b"PLTE", b"\x10\x20\x30"))
        }
        chunks.push(png_validation_chunk(kind, payload))
        chunks.push(png_validation_idat(b"\x00\x00\x00\x00\x00"))
        chunks.push(png_validation_chunk(b"IEND", b""))
        try {
          let _ = @image.decode_png(png_validation_png(chunks))
        } catch {
          _ => ()
        }
      }
    }
  }
}
