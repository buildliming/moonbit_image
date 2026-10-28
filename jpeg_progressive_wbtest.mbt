// A malformed scan must fail before allocating dimension-sized coefficient arrays.

///|
test "jpeg_progressive_metadata_and_bad_scans_do_not_allocate_planes" {
  let dc = build_jht([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0])
  let quantization = [Array::make(64, 1)]
  for
    (scan, message) in [
      (b"\x01\x01\x00\x00\x01\x00", "JPEG: invalid progressive scan parameters"),
      (b"\x01\x01\x00\x00\x00\x00\x00", "JPEG: missing EOI marker"),
      (
        b"\x01\x01\x00\x00\x00\x00\x00\xFF\xD9", "JPEG: truncated progressive DC scan",
      ),
    ] {
    // This layout is within budget but would otherwise reserve 64 MiB at SOF2.
    let state = jpg_progress_new(4096, 4096, [1], [1], [1], [0])
    assert_eq(state.coefficients[0].length(), 0)
    let error = try {
      let _ = jpg_progress_scan(state, scan, 0, 6, quantization, [dc], [], 0)
      "accepted invalid scan"
    } catch {
      Failure::Failure(message) => message
    }
    assert_eq(error, message)
    assert_eq(state.coefficients[0].length(), 0)
  }
}

///|
test "jpeg_progressive_allocates_only_components_in_a_valid_scan" {
  let state = jpg_progress_new(8, 8, [1, 2, 3], [1, 1, 1], [1, 1, 1], [0, 0, 0])
  let dc = build_jht([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0])
  // One zero DC coefficient followed by seven one-valued padding bits.
  let data = b"\x01\x01\x00\x00\x00\x00\x7F\xFF\xD9"
  let _ = jpg_progress_scan(
    state,
    data,
    0,
    6,
    [Array::make(64, 1)],
    [dc],
    [],
    0,
  )
  assert_eq(state.coefficients[0].length(), 64)
  assert_eq(state.coefficients[1].length(), 0)
  assert_eq(state.coefficients[2].length(), 0)
}
