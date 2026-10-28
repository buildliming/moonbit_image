// Resource-path regressions use small inputs; no test allocates a limit-sized
// image simply to exercise a rejection.

///|
fn resource_png_chunk(kind : Bytes, payload : Bytes) -> Bytes {
  let output = Buffer()
  output.write_int_be(payload.length())
  output.write_bytes(kind)
  output.write_bytes(payload)
  output.write_int_be(crc32_chunk(kind, payload))
  output.to_bytes()
}

///|
fn resource_png_header(
  width : Int,
  height : Int,
  depth : Byte,
  color : Byte,
) -> Bytes {
  let header = Buffer()
  header.write_int_be(width)
  header.write_int_be(height)
  header.write_byte(depth)
  header.write_byte(color)
  header.write_bytes(b"\x00\x00\x00")
  let png = Buffer()
  png.write_bytes(b"\x89PNG\r\n\x1A\n")
  png.write_bytes(resource_png_chunk(b"IHDR", header.to_bytes()))
  png.to_bytes()
}

///|
test "resource_png_rejects_oversized_IHDR_before_compressed_chunks" {
  for
    (width, height, depth, color, expected) in [
      (
        32768, 32768, b'\x08', b'\x06', "Image: decoded buffer exceeds 256 MiB limit",
      ),
      (8192, 8192, b'\x10', b'\x02', "PNG: image too large"),
    ] {
    let error = try {
      let _ = decode_png(resource_png_header(width, height, depth, color))
      "accepted oversized header"
    } catch {
      Failure::Failure(message) => message
    }
    assert_eq(error, expected)
  }
}

///|
test "resource_png_ignores_metadata_and_handles_split_IDAT" {
  let png = Buffer()
  png.write_bytes(resource_png_header(1, 1, b'\x08', b'\x00'))
  png.write_bytes(resource_png_chunk(b"tEXt", Bytes::makei(65536, _ => b'x')))
  // A zlib stored block containing the filter byte and one grayscale sample.
  png.write_bytes(resource_png_chunk(b"IDAT", b"\x78\x01\x01\x02"))
  png.write_bytes(
    resource_png_chunk(b"IDAT", b"\x00\xFD\xFF\x00\x7F\x00\x81\x00\x80"),
  )
  png.write_bytes(resource_png_chunk(b"IEND", b""))
  assert_eq(decode_png(png.to_bytes()).data, b"\x7F")
}

///|
test "resource_gif_keeps_only_loop_prefix_but_validates_entire_chain" {
  let blocks = b"\x01\x01\x01\x02\x04\x03\xAA\xBB\xCC\x00\x7F"
  let (prefix, position) = read_sub_blocks(blocks, 0, prefix_bytes=Some(3))
  assert_eq(prefix, b"\x01\x02\x03")
  assert_eq(position, 10)
  let (ignored, skipped) = read_sub_blocks(blocks, 0, keep=false)
  assert_eq(ignored, b"")
  assert_eq(skipped, position)
  let rejected = try {
    let _ = read_sub_blocks(
      b"\x03\x01\x02\x03\x02\xAA",
      0,
      prefix_bytes=Some(3),
    )
    false
  } catch {
    Failure::Failure(_) => true
  }
  assert_true(rejected)
}

///|
test "resource_gif_retained_frames_do_not_alias_mutable_canvas" {
  let gif = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\xFF\x00\x00\x00\x00\xFF\x2C\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x2C\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x4C\x01\x00\x3B"
  let animation = decode_gif_all(gif)
  assert_eq(animation.frames.length(), 2)
  assert_eq(animation.frames[0].data, b"\xFF\x00\x00\xFF")
  assert_eq(animation.frames[1].data, b"\x00\x00\xFF\xFF")
  assert_eq(decode_gif(gif).data, animation.frames[0].data)
}
