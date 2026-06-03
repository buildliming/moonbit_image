// Copyright (c) 2025 lws
// Byte reading utilities for image decoding

//-----------------------------------------------------------------------------
// Byte-level reading helpers
//-----------------------------------------------------------------------------

/// Read a single byte at position from Bytes
fn read_byte(data : Bytes, pos : Int) -> Int raise Failure {
  if pos >= data.length() {
    raise Failure::Failure("read_byte: position out of bounds")
  }
  data[pos].to_int()
}

/// Read a 16-bit unsigned integer in little-endian byte order
fn read_u16_le(data : Bytes, pos : Int) -> Int raise Failure {
  if pos + 2 > data.length() {
    raise Failure::Failure("read_u16_le: position out of bounds")
  }
  let lo = data[pos].to_int()
  let hi = data[pos + 1].to_int()
  lo | (hi << 8)
}

/// Read a 32-bit unsigned integer in little-endian byte order
fn read_u32_le(data : Bytes, pos : Int) -> Int raise Failure {
  if pos + 4 > data.length() {
    raise Failure::Failure("read_u32_le: position out of bounds")
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

/// Read a 32-bit unsigned integer in big-endian byte order
fn read_u32_be(data : Bytes, pos : Int) -> Int raise Failure {
  if pos + 4 > data.length() {
    raise Failure::Failure("read_u32_be: position out of bounds")
  }
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

/// Read a 16-bit unsigned integer in big-endian byte order
fn read_u16_be(data : Bytes, pos : Int) -> Int raise Failure {
  if pos + 2 > data.length() {
    raise Failure::Failure("read_u16_be: position out of bounds")
  }
  let hi = data[pos].to_int()
  let lo = data[pos + 1].to_int()
  (hi << 8) | lo
}

/// Convert an Int to a Byte (clamping to 0-255)
fn to_byte(v : Int) -> Byte {
  if v < 0 {
    b'\x00'
  } else if v > 255 {
    b'\xFF'
  } else {
    v.to_byte()
  }
}

/// Clamp an Int value to the range [0, 255]
fn clamp_u8(v : Int) -> Int {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

//-----------------------------------------------------------------------------
// CRC-32 checksum (used by PNG)
//-----------------------------------------------------------------------------

/// Pre-computed CRC-32 lookup table (computed once at module init)
let crc32_table : Array[Int] = make_crc32_table()

/// Logical right shift: forces unsigned semantics by masking out sign-extended bits
fn lsr8(v : Int) -> Int { (v >> 8) & 0x00FFFFFF }
fn lsr1(v : Int) -> Int { (v >> 1) & 0x7FFFFFFF }

fn make_crc32_table() -> Array[Int] {
  let table = Array::make(256, 0)
  for i = 0; i < 256; i = i + 1 {
    let mut c = i
    for _j = 0; _j < 8; _j = _j + 1 {
      if (c & 1) != 0 {
        c = 0xEDB88320 ^ lsr1(c)
      } else {
        c = lsr1(c)
      }
    }
    table[i] = c
  }
  table
}

/// Compute CRC-32 checksum over the given bytes
fn crc32(data : Bytes) -> Int {
  let mut c = 0xFFFFFFFF
  for i = 0; i < data.length(); i = i + 1 {
    let byte_val = data[i].to_int()
    let idx = ((c ^ byte_val) & 0xFF)
    c = crc32_table[idx] ^ lsr8(c)
  }
  c ^ 0xFFFFFFFF
}

/// Compute CRC-32 over multiple Bytes segments efficiently without concatenation
/// Pass previous crc32 result as `initial` to continue (use 0 for first segment)
fn crc32_update(initial : Int, data : Bytes) -> Int {
  let mut c = initial ^ 0xFFFFFFFF
  for i = 0; i < data.length(); i = i + 1 {
    let byte_val = data[i].to_int()
    let idx = ((c ^ byte_val) & 0xFF)
    c = crc32_table[idx] ^ lsr8(c)
  }
  c ^ 0xFFFFFFFF
}

/// Convenience: compute CRC-32 of chunk_type + chunk_data without allocating
fn crc32_chunk(chunk_type : Bytes, chunk_data : Bytes) -> Int {
  let initial = crc32_update(0, chunk_type)
  crc32_update(initial, chunk_data)
}

//-----------------------------------------------------------------------------
// Adler-32 checksum (used by zlib/DEFLATE)
//-----------------------------------------------------------------------------

/// Compute Adler-32 checksum over the given bytes
fn adler32(data : Bytes) -> Int {
  let mut s1 = 1
  let mut s2 = 0
  let prime = 65521
  for i = 0; i < data.length(); i = i + 1 {
    let byte_val = data[i].to_int()
    s1 = (s1 + byte_val) % prime
    s2 = (s2 + s1) % prime
  }
  (s2 << 16) | s1
}
