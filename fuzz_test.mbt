// Copyright (c) 2025 lws
// Fuzz testing for image decoders
//
// Feeds random byte sequences to each decoder and verifies
// they either succeed or raise Failure (never crash/panic).

//-----------------------------------------------------------------------------
// Simple pseudo-random number generator (LCG)
//-----------------------------------------------------------------------------

///|
/// LCG multiplier (Numerical Recipes)
const LCG_MULTIPLIER = 1664525

///|
/// LCG increment
const LCG_INCREMENT = 1013904223

///|
/// Advance the LCG state and return a pseudo-random byte value (0..255)
fn next_random(state : Int) -> (Int, Int) {
  let new_state = (state * LCG_MULTIPLIER + LCG_INCREMENT) & 0x7FFFFFFF
  let value = (new_state >> 7) & 0xFF
  return (new_state, value)
}

///|
/// Generate random Bytes of specified length using the LCG
fn random_bytes(seed : Int, length : Int) -> Bytes {
  let buf = Array::make(length, b'\x00')
  let mut state = seed
  for i = 0; i < length; i = i + 1 {
    let (s, v) = next_random(state)
    state = s
    buf[i] = v.to_byte()
  }
  Bytes::from_array(buf)
}

//-----------------------------------------------------------------------------
// Fuzz Tests — each generates 100 random inputs, verifies no crash
//-----------------------------------------------------------------------------

///|
/// Fuzz the BMP decoder with random data
test "fuzz_bmp" {
  let seed = 12345
  let mut state = seed
  for i = 0; i < 100; i = i + 1 {
    let (s, _len_seed) = next_random(state)
    state = s
    let (s2, len_seed2) = next_random(state)
    state = s2
    let length = 10 + len_seed2 % 500 // 10..510 bytes
    let data = random_bytes(state, length)
    try {
      let img = decode_bmp(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => () // Expected: random data is likely invalid
    }
  }
}

///|
/// Fuzz the QOI decoder with random data
test "fuzz_qoi" {
  let seed = 23456
  let mut state = seed
  for i = 0; i < 100; i = i + 1 {
    let (s, _) = next_random(state)
    state = s
    let (s2, len_seed) = next_random(state)
    state = s2
    let length = 10 + len_seed % 500
    let data = random_bytes(state, length)
    try {
      let img = decode_qoi(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}

///|
/// Fuzz the TGA decoder with random data
test "fuzz_tga" {
  let seed = 34567
  let mut state = seed
  for i = 0; i < 100; i = i + 1 {
    let (s, _) = next_random(state)
    state = s
    let (s2, len_seed) = next_random(state)
    state = s2
    let length = 10 + len_seed % 500
    let data = random_bytes(state, length)
    try {
      let img = decode_tga(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}

///|
/// Fuzz the PNG decoder with random data
test "fuzz_png" {
  let seed = 45678
  let mut state = seed
  for i = 0; i < 100; i = i + 1 {
    let (s, _) = next_random(state)
    state = s
    let (s2, len_seed) = next_random(state)
    state = s2
    let length = 10 + len_seed % 500
    let data = random_bytes(state, length)
    try {
      let img = decode_png(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}

///|
/// Fuzz the GIF decoder with random data
test "fuzz_gif" {
  let seed = 56789
  let mut state = seed
  for i = 0; i < 100; i = i + 1 {
    let (s, _) = next_random(state)
    state = s
    let (s2, len_seed) = next_random(state)
    state = s2
    let length = 10 + len_seed % 500
    let data = random_bytes(state, length)
    try {
      let img = decode_gif(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}

///|
/// Fuzz the JPEG decoder with random data
test "fuzz_jpeg" {
  let seed = 67890
  let mut state = seed
  for i = 0; i < 100; i = i + 1 {
    let (s, _) = next_random(state)
    state = s
    let (s2, len_seed) = next_random(state)
    state = s2
    let length = 10 + len_seed % 500
    let data = random_bytes(state, length)
    try {
      let img = decode_jpeg(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}

///|
/// Fuzz format detection with random data
test "fuzz_detect_format" {
  let seed = 78901
  let mut state = seed
  for i = 0; i < 200; i = i + 1 {
    let (s, _) = next_random(state)
    state = s
    let (s2, len_seed) = next_random(state)
    state = s2
    let length = 5 + len_seed % 100
    let data = random_bytes(state, length)
    // Detect format should never crash, always return Option
    let _ = detect_format(data)
  }
}

//-----------------------------------------------------------------------------
// Edge case fuzz: exactly-at-boundary data sizes
//-----------------------------------------------------------------------------

///|
/// Test BMP with data exactly at known boundary points
test "fuzz_bmp_boundary" {
  // Tests with exact boundary sizes that may trigger edge cases
  let test_sizes = [0, 1, 2, 14, 18, 26, 54, 100, 138, 256, 512, 1024]
  let seed = 99999
  for i = 0; i < test_sizes.length(); i = i + 1 {
    let size = test_sizes[i]
    let data = random_bytes(seed + i, size)
    try {
      let img = decode_bmp(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}

///|
/// Test PNG with data exactly at known boundary points
test "fuzz_png_boundary" {
  let test_sizes = [0, 1, 8, 33, 64, 100, 128, 256, 512, 1024]
  let seed = 88888
  for i = 0; i < test_sizes.length(); i = i + 1 {
    let size = test_sizes[i]
    let data = random_bytes(seed + i, size)
    try {
      let img = decode_png(data)
      let _w = img.width
      let _h = img.height
      ()
    } catch {
      _ => ()
    }
  }
}
