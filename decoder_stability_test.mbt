// Exercise the actual public decoders with reproducible, structurally valid seeds.
// Recoverable Failure is allowed for mutations; traps and invalid Images fail.

///|
fn stability_assert_image(image : @image.Image) -> Unit raise {
  assert_true(image.width > 0 && image.height > 0)
  let expected = image.width.to_int64() *
    image.height.to_int64() *
    image.bytes_per_pixel().to_int64()
  assert_eq(image.data.length().to_int64(), expected)
  let rgba = image.to_rgba8()
  assert_eq(
    rgba.data.length().to_int64(),
    image.width.to_int64() * image.height.to_int64() * 4L,
  )
}

///|
fn stability_attempt(data : Bytes) -> Unit raise {
  let decoded = Some(@image.decode(data)) catch { Failure::Failure(_) => None }
  if decoded is Some(image) {
    stability_assert_image(image)
  }
}

///|
test "decoder_stability_dispatch_and_repeatability" {
  for
    data in [
      make_test_bmp(),
      make_test_qoi(),
      make_test_tga(),
      make_test_png(),
      make_test_gif_2x2(),
      make_test_jpg_4x4(),
    ] {
    let image = @image.decode(data)
    stability_assert_image(image)
    let (w, h, format) = @image.image_dimensions(data)
    assert_eq(image.width, w)
    assert_eq(image.height, h)
    assert_eq(@image.decode_by_format(data, format).data, image.data)
    for iteration = 0; iteration < 10; iteration = iteration + 1 {
      assert_eq(@image.decode(data).data, image.data)
    }
  }
}

///|
test "decoder_stability_every_truncated_prefix" {
  for
    data in [
      make_test_bmp(),
      make_test_qoi(),
      make_test_tga(),
      make_test_png(),
      make_test_gif_2x2(),
      make_test_jpg_4x4(),
    ] {
    for length = 0; length < data.length(); length = length + 1 {
      stability_attempt(data[:length].to_owned())
    }
  }
}

///|
test "decoder_stability_seeded_body_mutations" {
  // Keep dimensions intact so these probes explore compressed data, not memory
  // exhaustion. Oversized headers are tested explicitly by format regressions.
  for
    (data, start) in [
      (make_test_bmp(), 54),
      (make_test_qoi(), 14),
      (make_test_tga(), 18),
      (make_test_png(), 33),
      (make_test_gif_2x2(), 13),
      (make_test_jpg_4x4(), make_test_jpg_4x4().length() - 6),
    ] {
    let mut state = 8675309U
    for iteration = 0; iteration < 128; iteration = iteration + 1 {
      let bytes = data.to_array()
      state = state * 1664525U + 1013904223U
      let position = start +
        (state % (data.length() - start).reinterpret_as_uint()).reinterpret_as_int()
      bytes[position] = (bytes[position].to_int() ^ (1 << (iteration % 8))).to_byte()
      stability_attempt(Bytes::from_array(bytes))
    }
  }
}

///|
test "decoder_stability_dimensions_reject_zero_and_signed_overflow" {
  for
    (data, positions) in [
      (make_test_bmp(), [18, 22]),
      (make_test_qoi(), [4, 8]),
      (make_test_tga(), [12, 14]),
      (make_test_png(), [16, 20]),
      (make_test_gif_2x2(), [6, 8]),
    ] {
    for position in positions {
      let bytes = data.to_array()
      bytes[position] = b'\x00'
      bytes[position + 1] = b'\x00'
      if data[0] != b'G' && data[0] != b'\x00' {
        bytes[position + 2] = b'\x00'
        bytes[position + 3] = b'\x00'
      }
      let rejected = try {
        let _ = @image.image_dimensions(Bytes::from_array(bytes))
        false
      } catch {
        Failure::Failure(_) => true
      }
      assert_true(rejected)
    }
  }
}
