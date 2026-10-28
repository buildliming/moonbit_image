// Copyright (c) 2025 lws
// JPEG baseline/progressive decoder — grayscale + YCbCr color
//
// Supports JFIF baseline (SOF0) and progressive (SOF2) JPEG with:
//   - Huffman-coded DC and AC coefficients (compact canonical tables)
//   - Zigzag deordering → dequantization → IDCT
//   - Grayscale (1-component) and YCbCr color (3-component, 4:4:4/4:2:2/4:2:0)
//   - Restart marker (RST) support
//   - Spectral selection and successive approximation (ITU-T T.81 Annex G)
//
// Performance optimizations:
//   - IDCT coefficients and zigzag table as module-level constants
//   - Huffman decoding via bounded canonical code tables
//   - Bulk bit reading (reads bytes directly when 8+ bits needed)
//   - JBR uses byte_pos + bit_pos representation

//-----------------------------------------------------------------------------
// Module-level constants (pre-computed once, not per-call)
//-----------------------------------------------------------------------------

///|
/// Zigzag scan order (JPEG spec Figure K.2)
let zigzag : Array[Int] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
  23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62,
  63,
]

///|
/// IDCT basis coefficients, scaled by 4096:
/// C(u)/2 * cos((2x+1)*u*pi/16), where C(0)=1/sqrt(2).
let dct_t : Array[Array[Int]] = [
  [1448, 1448, 1448, 1448, 1448, 1448, 1448, 1448],
  [2009, 1703, 1138, 400, -400, -1138, -1703, -2009],
  [1892, 784, -784, -1892, -1892, -784, 784, 1892],
  [1703, -400, -2009, -1138, 1138, 2009, 400, -1703],
  [1448, -1448, -1448, 1448, 1448, -1448, -1448, 1448],
  [1138, -2009, 400, 1703, -1703, -400, 2009, -1138],
  [784, -1892, 1892, -784, -784, 1892, -1892, 784],
  [400, -1138, 1703, -2009, 2009, -1703, 1138, -400],
]

//-----------------------------------------------------------------------------
// Bit reader (MSB-first, used for JPEG Huffman-coded data)
//-----------------------------------------------------------------------------

///|
/// JPEG bit reader. Uses byte_pos + bit_pos representation for efficient
/// bulk reading.
/// Fields are named differently from BitReader to avoid type ambiguity.
priv struct JBR {
  buf : Bytes // entropy-coded data (with 0xFF00 stuffing already stripped)
  bp : Int // current byte position
  bitp : Int // next bit to read within byte (0=MSB, 7=LSB)
}

///|
fn JBR::new(data : Bytes) -> JBR {
  { buf: data, bp: 0, bitp: 0, }
}

///|
/// Read n bits MSB-first. Returns (new_reader, value).
/// Uses bulk byte reading when byte-aligned for efficiency.
fn JBR::read_bits(self : JBR, n : Int) -> (JBR, Int) raise Failure {
  if n == 0 {
    return (self, 0)
  }

  let mut bp_idx = self.bp
  let mut bit_pos = self.bitp
  let mut result = 0
  let mut needed = n

  // Fast path: byte-aligned, reading 8+ bits → read whole bytes
  while needed >= 8 && bit_pos == 0 {
    if bp_idx >= self.buf.length() {
      raise Failure::Failure("JPEG: unexpected end of entropy data")
    }
    result = (result << 8) | self.buf[bp_idx].to_int()
    bp_idx = bp_idx + 1
    needed = needed - 8
  }

  // Remaining bits (either not byte-aligned, or < 8 bits left)
  while needed > 0 {
    if bp_idx >= self.buf.length() {
      raise Failure::Failure("JPEG: unexpected end of entropy data")
    }
    let byte = self.buf[bp_idx].to_int()
    let bits_left = 8 - bit_pos
    let take = if needed < bits_left { needed } else { bits_left }
    // Extract bits from the current position within the byte (MSB-first)
    let val = (byte >> (bits_left - take)) & ((1 << take) - 1)
    result = (result << take) | val
    needed = needed - take
    if take == bits_left {
      bp_idx = bp_idx + 1
      bit_pos = 0
    } else {
      bit_pos = bit_pos + take
    }
  }

  ({ buf: self.buf, bp: bp_idx, bitp: bit_pos, }, result)
}

//-----------------------------------------------------------------------------
// JPEG Huffman table with compact canonical codes
//-----------------------------------------------------------------------------

///|
/// At most 304 integers per table, including all 256 possible symbols.
priv struct JHT {
  counts : Array[Int]
  first_code : Array[Int]
  first_symbol : Array[Int]
  symbols : Array[Int]
  tbl_bits : Int
}

///|
/// Build canonical code ranges from BITS and HUFFVAL arrays.
fn build_jht(bits : Array[Int], hv_in : Array[Int]) -> JHT raise Failure {
  // Find the maximum code length
  let mut max_len = 0
  for l = 1; l <= 16; l = l + 1 {
    if bits[l - 1] > 0 {
      max_len = l
    }
  }
  if max_len == 0 {
    raise Failure::Failure("JPEG: empty Huffman table")
  }
  // JPEG reserves the all-ones code for entropy padding (T.81 C.2).
  let mut remaining = 1
  for l = 1; l <= 16; l = l + 1 {
    remaining = (remaining << 1) - bits[l - 1]
    if remaining <= 0 {
      raise Failure::Failure("JPEG: invalid Huffman code lengths")
    }
  }

  let first_code = Array::make(16, 0)
  let first_symbol = Array::make(16, 0)
  let mut code = 0
  let mut si = 0
  for i = 0; i < 16; i = i + 1 {
    first_code[i] = code
    first_symbol[i] = si
    si = si + bits[i]
    code = (code + bits[i]) << 1
  }
  { counts: bits, first_code, first_symbol, symbols: hv_in, tbl_bits: max_len, }
}

///|
/// Decode with at most 16 bounded code-range checks, without a 64K lookup table.
fn jht_decode(ht : JHT, r : JBR) -> (JBR, Int) raise Failure {
  let mut reader = r
  let mut code = 0
  for i = 0; i < ht.tbl_bits; i = i + 1 {
    let (nr, bit) = reader.read_bits(1)
    reader = nr
    code = (code << 1) | bit
    let index = code - ht.first_code[i]
    if index >= 0 && index < ht.counts[i] {
      return (reader, ht.symbols[ht.first_symbol[i] + index])
    }
  }
  raise Failure::Failure("JPEG: bad Huffman code")
}

//-----------------------------------------------------------------------------
// IDCT (Inverse Discrete Cosine Transform)
//-----------------------------------------------------------------------------

///|
/// 2-D IDCT: keep signed precision between passes, then level-shift once.
/// Int64 intermediates prevent overflow from high-frequency coefficients.
fn idct_2d(block : Array[Int]) -> Array[Int] {
  let t = Array::make(64, 0L)
  for v = 0; v < 8; v = v + 1 {
    for x = 0; x < 8; x = x + 1 {
      let mut sum = 0L
      for u = 0; u < 8; u = u + 1 {
        sum = sum +
          Int64::from_int(block[v * 8 + u]) * Int64::from_int(dct_t[u][x])
      }
      t[v * 8 + x] = sum
    }
  }
  let res = Array::make(64, 0)
  for y = 0; y < 8; y = y + 1 {
    for x = 0; x < 8; x = x + 1 {
      let mut sum = 0L
      for v = 0; v < 8; v = v + 1 {
        sum = sum + t[v * 8 + x] * Int64::from_int(dct_t[v][y])
      }
      let pixel = ((sum + 8388608L) >> 24) + 128L
      res[y * 8 + x] = if pixel < 0L {
        0
      } else if pixel > 255L {
        255
      } else {
        pixel.to_int()
      }
    }
  }
  res
}

//-----------------------------------------------------------------------------
// JPEG Decoder Helper Functions
//-----------------------------------------------------------------------------

///|
/// Decode DC coefficient. Returns (reader, new_value, new_pred).
fn jpg_dc(r : JBR, ht : JHT, pred : Int) -> (JBR, Int, Int) raise Failure {
  let (r2, cat) = jht_decode(ht, r)
  if cat > 11 {
    raise Failure::Failure("JPEG: invalid DC category")
  }
  if cat == 0 {
    return (r2, pred, pred)
  }
  let (r3, bits) = r2.read_bits(cat)
  let half = 1 << (cat - 1)
  let diff = if bits < half { bits - ((1 << cat) - 1) } else { bits }
  let new_val = pred + diff
  if new_val < -2048 || new_val > 2047 {
    raise Failure::Failure("JPEG: DC coefficient out of range")
  }
  (r3, new_val, new_val)
}

///|
/// Decode AC coefficients for one 8x8 block.
/// Writes decoded values to block[] at zigzag positions.
/// Returns the updated reader.
fn jpg_ac(r : JBR, ht : JHT, block : Array[Int]) -> JBR raise Failure {
  let mut reader = r
  let mut k = 1
  while k < 64 {
    let (r2, sym) = jht_decode(ht, reader)
    reader = r2
    if sym == 0 {
      return reader
    } // EOB
    let rs = sym >> 4
    let sz = sym & 0xF
    if sz > 10 || (sz == 0 && rs != 15) {
      raise Failure::Failure("JPEG: invalid AC category")
    }
    if sz == 0 && rs == 15 {
      // ZRL: 16 zeros
      k = k + 16
      if k > 64 {
        raise Failure::Failure("JPEG: AC zero run exceeds block")
      }
      continue
    }
    k = k + rs
    if k >= 64 {
      raise Failure::Failure("JPEG: AC run exceeds block")
    }
    if sz > 0 {
      let (r3, bits) = reader.read_bits(sz)
      reader = r3
      let half = 1 << (sz - 1)
      let val = if bits < half { bits - ((1 << sz) - 1) } else { bits }
      let zi = zigzag[k]
      if zi < 64 {
        block[zi] = val
      }
    }
    k = k + 1
  }
  reader
}

///|
/// Decode one 8x8 block. Returns (reader, new_dc_pred, pixel_array[64]).
fn jpg_block(
  r : JBR,
  dc_ht : JHT,
  ac_ht : JHT,
  qt : Array[Int],
  dc_pred : Int,
) -> (JBR, Int, Array[Int]) raise Failure {
  let block = Array::make(64, 0)
  let (r2, _dc_val, ndc) = jpg_dc(r, dc_ht, dc_pred)
  let r3 = jpg_ac(r2, ac_ht, block)
  block[0] = ndc
  // Dequantize
  for i = 0; i < 64; i = i + 1 {
    block[i] = block[i] * qt[i]
  }
  (r3, ndc, idct_2d(block))
}

//-----------------------------------------------------------------------------
// YCbCr → RGB conversion (ITU-R BT.601, 12-bit fixed point)
//-----------------------------------------------------------------------------

///|
/// Convert YCbCr to RGB using ITU-R BT.601 coefficients with 12 fractional bits.
/// All values are clamped to [0, 255].
fn ycbcr_to_rgb(y : Int, cb : Int, cr : Int) -> (Int, Int, Int) {
  let cb_off = cb - 128
  let cr_off = cr - 128

  // R = Y + 1.40200 * (Cr-128)  →  R = Y + 5743 * Cr_off / 4096
  let r = y + ((5743 * cr_off + 2048) >> 12)
  // G = Y - 0.34414 * (Cb-128) - 0.71414 * (Cr-128)
  let g = y - ((1410 * cb_off + 2925 * cr_off + 2048) >> 12)
  // B = Y + 1.77200 * (Cb-128)  →  B = Y + 7258 * Cb_off / 4096
  let b = y + ((7258 * cb_off + 2048) >> 12)

  let r_clamp = if r < 0 { 0 } else if r > 255 { 255 } else { r }
  let g_clamp = if g < 0 { 0 } else if g > 255 { 255 } else { g }
  let b_clamp = if b < 0 { 0 } else if b > 255 { 255 } else { b }

  (r_clamp, g_clamp, b_clamp)
}

///|
/// Interpolate subsampled chroma at pixel centers with replicated edge samples.
/// Alternate rounding follows the conventional libjpeg triangle upsampler.
fn jpg_chroma(
  plane : Array[Byte],
  stride : Int,
  width : Int,
  height : Int,
  x : Int,
  y : Int,
  horizontal : Int,
  vertical : Int,
) -> Int {
  let sx = x / horizontal
  let sy = y / vertical
  if horizontal == 1 || width <= 2 {
    return plane[sy * stride + sx].to_int()
  }
  let nx = if x % 2 == 0 {
    if sx > 0 {
      sx - 1
    } else {
      sx
    }
  } else if sx + 1 < width {
    sx + 1
  } else {
    sx
  }
  let center = plane[sy * stride + sx].to_int()
  let neighbor = plane[sy * stride + nx].to_int()
  if vertical == 1 {
    let bias = if x % 2 == 0 { 1 } else { 2 }
    return (center * 3 + neighbor + bias) >> 2
  }
  let ny = if y % 2 == 0 {
    if sy > 0 {
      sy - 1
    } else {
      sy
    }
  } else if sy + 1 < height {
    sy + 1
  } else {
    sy
  }
  let center_sum = center * 3 + plane[ny * stride + sx].to_int()
  let neighbor_sum = neighbor * 3 + plane[ny * stride + nx].to_int()
  let bias = if x % 2 == 0 { 8 } else { 7 }
  (center_sum * 3 + neighbor_sum + bias) >> 4
}

//-----------------------------------------------------------------------------
// Main JPEG decoder
//-----------------------------------------------------------------------------

///|
/// Read a complete marker and its bounded payload, accepting marker fill bytes.
fn jpg_segment(data : Bytes, offset : Int) -> (Int, Int, Int) raise Failure {
  let mut pos = offset
  if pos >= data.length() || data[pos].to_int() != 0xFF {
    raise Failure::Failure("JPEG: expected marker")
  }
  while pos < data.length() && data[pos].to_int() == 0xFF {
    pos = pos + 1
  }
  if pos >= data.length() {
    raise Failure::Failure("JPEG: truncated marker")
  }
  let marker = data[pos].to_int()
  pos = pos + 1
  if marker == 0xD9 {
    return (marker, pos, pos)
  }
  if marker == 0 ||
    marker == 0xD8 ||
    marker == 1 ||
    (marker >= 0xD0 && marker <= 0xD7) {
    raise Failure::Failure("JPEG: unexpected standalone marker")
  }
  if data.length() - pos < 2 {
    raise Failure::Failure("JPEG: truncated segment length")
  }
  let length = (data[pos].to_int() << 8) | data[pos + 1].to_int()
  if length < 2 || length > data.length() - pos {
    raise Failure::Failure("JPEG: invalid segment length")
  }
  (marker, pos + 2, pos + length)
}

///|
/// Validate a supported eight-bit DCT frame and return component descriptors.
fn jpg_frame(
  data : Bytes,
  pos : Int,
  end : Int,
) -> (Int, Int, Array[Int], Array[Int], Array[Int], Array[Int]) raise Failure {
  if end - pos < 6 || data[pos].to_int() != 8 {
    raise Failure::Failure("JPEG: requires eight-bit samples")
  }
  let h = (data[pos + 1].to_int() << 8) | data[pos + 2].to_int()
  let w = (data[pos + 3].to_int() << 8) | data[pos + 4].to_int()
  let nc = data[pos + 5].to_int()
  if (nc != 1 && nc != 3) || end - pos != 6 + nc * 3 {
    raise Failure::Failure("JPEG: unsupported or invalid component count")
  }
  let _ = checked_image_size(w, h, nc)
  let ids = Array::make(nc, 0)
  let hs = Array::make(nc, 0)
  let vs = Array::make(nc, 0)
  let tables = Array::make(nc, 0)
  for i = 0; i < nc; i = i + 1 {
    let start = pos + 6 + i * 3
    ids[i] = data[start].to_int()
    let sampling = data[start + 1].to_int()
    hs[i] = sampling >> 4
    vs[i] = sampling & 15
    tables[i] = data[start + 2].to_int()
    if tables[i] >= 4 {
      raise Failure::Failure("JPEG: invalid quantization table selector")
    }
    for j = 0; j < i; j = j + 1 {
      if ids[j] == ids[i] {
        raise Failure::Failure("JPEG: duplicate frame component")
      }
    }
  }
  if nc == 1 {
    if hs[0] < 1 || hs[0] > 4 || vs[0] < 1 || vs[0] > 4 {
      raise Failure::Failure("JPEG: invalid grayscale sampling")
    }
    // A noninterleaved grayscale MCU is one block regardless of frame sampling.
    hs[0] = 1
    vs[0] = 1
    // The output path implements conventional JFIF Y,Cb,Cr component order.
  } else if ids != [1, 2, 3] ||
    hs[1] != 1 ||
    vs[1] != 1 ||
    hs[2] != 1 ||
    vs[2] != 1 ||
    !((hs[0] == 1 && vs[0] == 1) || (hs[0] == 2 && (vs[0] == 1 || vs[0] == 2))) {
    raise Failure::Failure("JPEG: unsupported color components or sampling")
  }
  (w, h, ids, hs, vs, tables)
}

///|
/// An entropy segment must end with at most seven one-valued padding bits.
fn jpg_finish_segment(reader : JBR) -> Unit raise Failure {
  let mut end = reader.bp
  if reader.bitp != 0 {
    let count = 8 - reader.bitp
    let mask = (1 << count) - 1
    if (reader.buf[end].to_int() & mask) != mask {
      raise Failure::Failure("JPEG: invalid entropy padding")
    }
    end = end + 1
  }
  if end != reader.buf.length() {
    raise Failure::Failure("JPEG: excess entropy data or misplaced restart")
  }
}

///|
/// Keep restart boundaries while removing entropy byte stuffing.
fn jpg_scan_entropy(
  data : Bytes,
  start : Int,
  restart_interval : Int,
  segment_count : Int,
) -> (Array[Bytes], Int) raise Failure {
  let segments = []
  let mut bytes = Buffer()
  let mut pos = start
  let mut next_restart = 0
  let mut byte_count = 0
  while pos < data.length() {
    if data[pos].to_int() != 0xFF {
      if byte_count >= MAX_DECODE_BYTES {
        raise Failure::Failure("JPEG: entropy data exceeds 256 MiB limit")
      }
      bytes.write_byte(data[pos])
      byte_count = byte_count + 1
      pos = pos + 1
      continue
    }
    let marker_start = pos
    pos = pos + 1
    if pos >= data.length() {
      raise Failure::Failure("JPEG: truncated entropy marker")
    }
    if data[pos].to_int() == 0 {
      if byte_count >= MAX_DECODE_BYTES {
        raise Failure::Failure("JPEG: entropy data exceeds 256 MiB limit")
      }
      bytes.write_byte(b'\xFF')
      byte_count = byte_count + 1
      pos = pos + 1
      continue
    }
    while pos < data.length() && data[pos].to_int() == 0xFF {
      pos = pos + 1
    }
    if pos >= data.length() {
      raise Failure::Failure("JPEG: truncated entropy marker")
    }
    let marker = data[pos].to_int()
    pos = pos + 1
    if marker >= 0xD0 && marker <= 0xD7 {
      if restart_interval == 0 ||
        marker != 0xD0 + next_restart ||
        segments.length() >= segment_count - 1 ||
        bytes.length() == 0 {
        raise Failure::Failure("JPEG: unexpected restart marker")
      }
      segments.push(bytes.to_bytes())
      bytes = Buffer()
      next_restart = (next_restart + 1) % 8
    } else {
      segments.push(bytes.to_bytes())
      return (segments, marker_start)
    }
  }
  raise Failure::Failure("JPEG: missing EOI marker")
}

///|
fn jpg_entropy(
  data : Bytes,
  start : Int,
  restart_interval : Int,
  segment_count : Int,
) -> Array[Bytes] raise Failure {
  let (segments, next) = jpg_scan_entropy(
    data, start, restart_interval, segment_count,
  )
  let mut pos = next
  while pos < data.length() {
    let (marker, _, end) = jpg_segment(data, pos)
    if marker == 0xD9 {
      return segments
    }
    if !((marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE) {
      raise Failure::Failure("JPEG: only a single baseline scan is supported")
    }
    pos = end
  }
  raise Failure::Failure("JPEG: missing EOI marker")
}

///|
/// Decode eight-bit baseline or progressive JPEG (grayscale or JFIF YCbCr).
pub fn decode_jpeg(data : Bytes) -> Image raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }
  let mut pos = 2
  let mut w = 0
  let mut h = 0
  let mut comp_id = []
  let mut comp_h = []
  let mut comp_v = []
  let mut comp_qt = []
  let qt = Array::make(4, Array::make(0, 0))
  let sentinel = JHT::{
    counts: [],
    first_code: [],
    first_symbol: [],
    symbols: [],
    tbl_bits: 0,
  }
  let dc_ht = Array::make(4, sentinel)
  let ac_ht = Array::make(4, sentinel)
  let mut restart_interval = 0
  let mut adobe_transform = -1
  let mut progressive = false
  let mut progress : JPGProgress? = None
  while pos < data.length() {
    let (marker, start, end) = jpg_segment(data, pos)
    pos = start
    if marker == 0xDB {
      if pos == end {
        raise Failure::Failure("JPEG: empty quantization segment")
      }
      while pos < end {
        let info = data[pos].to_int()
        pos = pos + 1
        if info >> 4 != 0 || (info & 15) >= 4 || end - pos < 64 {
          raise Failure::Failure(
            "JPEG: unsupported or invalid quantization table",
          )
        }
        let table = Array::make(64, 0)
        for i = 0; i < 64; i = i + 1 {
          let value = data[pos + i].to_int()
          if value == 0 {
            raise Failure::Failure("JPEG: zero quantization value")
          }
          table[zigzag[i]] = value
        }
        qt[info & 15] = table
        pos = pos + 64
      }
    } else if marker == 0xC0 || marker == 0xC2 {
      if w != 0 {
        raise Failure::Failure("JPEG: duplicate frame")
      }
      let (fw, fh, ids, hs, vs, tables) = jpg_frame(data, start, end)
      w = fw
      h = fh
      comp_id = ids
      comp_h = hs
      comp_v = vs
      comp_qt = tables
      progressive = marker == 0xC2
      if !progressive {
        // DHT is permitted before SOF, so defer process-specific validation.
        for index = 0; index < 4; index = index + 1 {
          if index > 1 &&
            (dc_ht[index].tbl_bits != 0 || ac_ht[index].tbl_bits != 0) {
            raise Failure::Failure("JPEG: invalid baseline Huffman selector")
          }
          for symbol in ac_ht[index].symbols {
            if (symbol & 15) == 0 && symbol != 0 && symbol != 0xF0 {
              raise Failure::Failure("JPEG: invalid baseline Huffman symbol")
            }
          }
        }
      }
    } else if marker == 0xC4 {
      if pos == end {
        raise Failure::Failure("JPEG: empty Huffman segment")
      }
      while pos < end {
        if end - pos < 17 {
          raise Failure::Failure("JPEG: truncated Huffman table")
        }
        let info = data[pos].to_int()
        pos = pos + 1
        let tc = info >> 4
        let th = info & 15
        if tc > 1 || th > 3 || (w != 0 && !progressive && th > 1) {
          raise Failure::Failure("JPEG: invalid Huffman selector")
        }
        let bits = Array::make(16, 0)
        let mut total = 0
        for i = 0; i < 16; i = i + 1 {
          bits[i] = data[pos + i].to_int()
          total = total + bits[i]
        }
        pos = pos + 16
        if total > 256 || total > end - pos {
          raise Failure::Failure("JPEG: invalid Huffman symbol count")
        }
        let values = Array::make(total, 0)
        let seen = Array::make(256, false)
        for i = 0; i < total; i = i + 1 {
          let value = data[pos + i].to_int()
          if seen[value] ||
            (tc == 0 && value > 11) ||
            (
              tc == 1 &&
              (
                (value & 15) > 10 ||
                (
                  w != 0 &&
                  !progressive &&
                  (value & 15) == 0 &&
                  value != 0 &&
                  value != 0xF0
                )
              )
            ) {
            raise Failure::Failure("JPEG: invalid Huffman symbol")
          }
          seen[value] = true
          values[i] = value
        }
        pos = pos + total
        let table = build_jht(bits, values)
        if tc == 0 {
          dc_ht[th] = table
        } else {
          ac_ht[th] = table
        }
      }
    } else if marker == 0xDD {
      if end - start != 2 {
        raise Failure::Failure("JPEG: invalid restart interval segment")
      }
      restart_interval = (data[start].to_int() << 8) | data[start + 1].to_int()
    } else if marker == 0xEE &&
      end - start >= 12 &&
      data[start:start + 5] == b"Adobe" {
      adobe_transform = data[start + 11].to_int()
    } else if marker == 0xDA {
      let nc = comp_id.length()
      if progressive {
        if nc == 3 && adobe_transform != -1 && adobe_transform != 1 {
          raise Failure::Failure("JPEG: unsupported Adobe color transform")
        }
        let state = match progress {
          Some(state) => state
          None => {
            let state = jpg_progress_new(w, h, comp_id, comp_h, comp_v, comp_qt)
            progress = Some(state)
            state
          }
        }
        pos = jpg_progress_scan(
          state, data, start, end, qt, dc_ht, ac_ht, restart_interval,
        )
        continue
      }
      if w == 0 ||
        end - start < 1 ||
        data[start].to_int() != nc ||
        end - start != 1 + nc * 2 + 3 {
        raise Failure::Failure("JPEG: invalid or unsupported scan components")
      }
      if nc == 3 && adobe_transform != -1 && adobe_transform != 1 {
        raise Failure::Failure("JPEG: unsupported Adobe color transform")
      }
      if data[end - 3].to_int() != 0 ||
        data[end - 2].to_int() != 63 ||
        data[end - 1].to_int() != 0 {
        raise Failure::Failure("JPEG: unsupported nonbaseline scan parameters")
      }
      let scan_comp = Array::make(nc, 0)
      let scan_dc = Array::make(nc, 0)
      let scan_ac = Array::make(nc, 0)
      let selected = Array::make(nc, false)
      for i = 0; i < nc; i = i + 1 {
        let id = data[start + 1 + i * 2].to_int()
        let selectors = data[start + 2 + i * 2].to_int()
        let dc = selectors >> 4
        let ac = selectors & 15
        let mut ci = -1
        for j = 0; j < nc; j = j + 1 {
          if comp_id[j] == id {
            ci = j
          }
        }
        if ci < 0 || dc > 1 || ac > 1 {
          raise Failure::Failure("JPEG: invalid scan selector")
        }
        if selected[ci] ||
          dc_ht[dc].tbl_bits == 0 ||
          ac_ht[ac].tbl_bits == 0 ||
          qt[comp_qt[ci]].length() != 64 {
          raise Failure::Failure(
            "JPEG: duplicate component or missing coding table",
          )
        }
        selected[ci] = true
        scan_comp[i] = ci
        scan_dc[i] = dc
        scan_ac[i] = ac
      }
      let max_h = comp_h[0]
      let max_v = comp_v[0]
      let mcus_x = (w + max_h * 8 - 1) / (max_h * 8)
      let mcus_y = (h + max_v * 8 - 1) / (max_v * 8)
      let segment_count = if restart_interval > 0 {
        (mcus_x * mcus_y - 1) / restart_interval + 1
      } else {
        1
      }
      let segments = jpg_entropy(data, end, restart_interval, segment_count)
      let widths = Array::make(nc, 0)
      let planes = Array::make(nc, Array::make(0, b'\x00'))
      for i = 0; i < nc; i = i + 1 {
        widths[i] = mcus_x * comp_h[i] * 8
        let plane_h = mcus_y * comp_v[i] * 8
        let size = checked_image_size(widths[i], plane_h, 1)
        planes[i] = Array::make(size, b'\x00')
      }
      let predictors = Array::make(nc, 0)
      let mut segment = 0
      let mut reader = JBR::new(segments[0])
      let mut mcu_count = 0
      for my = 0; my < mcus_y; my = my + 1 {
        for mx = 0; mx < mcus_x; mx = mx + 1 {
          for sc = 0; sc < nc; sc = sc + 1 {
            let ci = scan_comp[sc]
            for vy = 0; vy < comp_v[ci]; vy = vy + 1 {
              for vx = 0; vx < comp_h[ci]; vx = vx + 1 {
                let (next, dc, pixels) = jpg_block(
                  reader,
                  dc_ht[scan_dc[sc]],
                  ac_ht[scan_ac[sc]],
                  qt[comp_qt[ci]],
                  predictors[ci],
                )
                reader = next
                predictors[ci] = dc
                let block_x = (mx * comp_h[ci] + vx) * 8
                let block_y = (my * comp_v[ci] + vy) * 8
                for py = 0; py < 8; py = py + 1 {
                  for px = 0; px < 8; px = px + 1 {
                    planes[ci][(block_y + py) * widths[ci] + block_x + px] = pixels[py *
                    8 +
                    px].to_byte()
                  }
                }
              }
            }
          }
          mcu_count = mcu_count + 1
          if restart_interval > 0 &&
            mcu_count % restart_interval == 0 &&
            mcu_count < mcus_x * mcus_y {
            jpg_finish_segment(reader)
            segment = segment + 1
            if segment >= segments.length() {
              raise Failure::Failure("JPEG: missing restart marker")
            }
            reader = JBR::new(segments[segment])
            for i = 0; i < nc; i = i + 1 {
              predictors[i] = 0
            }
          }
        }
      }
      jpg_finish_segment(reader)
      if segment != segments.length() - 1 {
        raise Failure::Failure("JPEG: excess restart marker")
      }
      let size = checked_image_size(w, h, nc)
      let out = Array::make(size, b'\x00')
      for y = 0; y < h; y = y + 1 {
        for x = 0; x < w; x = x + 1 {
          if nc == 1 {
            out[y * w + x] = planes[0][y * widths[0] + x]
          } else {
            let chroma_w = (w + max_h - 1) / max_h
            let chroma_h = (h + max_v - 1) / max_v
            let (r, g, b) = ycbcr_to_rgb(
              planes[0][y * widths[0] + x].to_int(),
              jpg_chroma(
                planes[1],
                widths[1],
                chroma_w,
                chroma_h,
                x,
                y,
                max_h,
                max_v,
              ),
              jpg_chroma(
                planes[2],
                widths[2],
                chroma_w,
                chroma_h,
                x,
                y,
                max_h,
                max_v,
              ),
            )
            let offset = (y * w + x) * 3
            out[offset] = r.to_byte()
            out[offset + 1] = g.to_byte()
            out[offset + 2] = b.to_byte()
          }
        }
      }
      let format = if nc == 1 { PixelFormat::Gray8 } else { PixelFormat::RGB8 }
      return Image::new(w, h, format, Bytes::from_array(out))
    } else if (marker >= 0xC1 && marker <= 0xCF) ||
      marker == 0xDC ||
      marker == 0xDE ||
      marker == 0xDF {
      raise Failure::Failure("JPEG: unsupported coding process")
    } else if marker == 0xD9 {
      if progress is Some(state) {
        if comp_id.length() == 3 &&
          adobe_transform != -1 &&
          adobe_transform != 1 {
          raise Failure::Failure("JPEG: unsupported Adobe color transform")
        }
        return jpg_progress_image(state)
      }
      break
    } else if !((marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE) {
      raise Failure::Failure("JPEG: unsupported marker")
    }
    pos = end
  }
  raise Failure::Failure("JPEG: no SOS marker found")
}

///|
/// Read dimensions of a supported baseline/progressive frame without pixels.
pub fn jpeg_dimensions(data : Bytes) -> (Int, Int) raise Failure {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise Failure::Failure("JPEG: missing SOI marker")
  }
  let mut pos = 2
  while pos < data.length() {
    let (marker, start, end) = jpg_segment(data, pos)
    if marker == 0xC0 || marker == 0xC2 {
      let (w, h, _, _, _, _) = jpg_frame(data, start, end)
      return (w, h)
    }
    if marker == 0xDA || marker == 0xD9 {
      break
    }
    if marker >= 0xC1 && marker <= 0xCF && marker != 0xC4 {
      raise Failure::Failure("JPEG: unsupported coding process")
    }
    pos = end
  }
  raise Failure::Failure("JPEG: no supported DCT frame found")
}

///|
/// Quantized coefficients survive scans; quantization is latched per component.
/// The progression map prevents duplicate bands/refinements and bounds scan work.
priv struct JPGProgress {
  width : Int
  height : Int
  ids : Array[Int]
  hs : Array[Int]
  vs : Array[Int]
  selectors : Array[Int]
  strides : Array[Int]
  rows : Array[Int]
  coefficients : Array[Array[Int]]
  levels : Array[Array[Int]]
  quantization : Array[Array[Int]]
}

///|
fn jpg_progress_new(
  width : Int,
  height : Int,
  ids : Array[Int],
  hs : Array[Int],
  vs : Array[Int],
  selectors : Array[Int],
) -> JPGProgress raise Failure {
  let nc = ids.length()
  let mx = (width + hs[0] * 8 - 1) / (hs[0] * 8)
  let my = (height + vs[0] * 8 - 1) / (vs[0] * 8)
  let strides = Array::make(nc, 0)
  let rows = Array::make(nc, 0)
  // Include coefficient storage, pixel planes and both output array/Bytes copies.
  let mut budget = width.to_int64() * height.to_int64() * nc.to_int64() * 2L
  for ci = 0; ci < nc; ci = ci + 1 {
    strides[ci] = mx * hs[ci]
    rows[ci] = my * vs[ci]
    budget = budget + strides[ci].to_int64() * rows[ci].to_int64() * 64L * 5L
  }
  if budget > MAX_DECODE_BYTES.to_int64() {
    raise Failure::Failure(
      "JPEG: progressive working buffers exceed 256 MiB limit",
    )
  }
  let coefficients = Array::make(nc, Array::make(0, 0))
  let levels = Array::make(nc, Array::make(0, 0))
  for ci = 0; ci < nc; ci = ci + 1 {
    levels[ci] = Array::make(64, -1)
  }
  {
    width,
    height,
    ids,
    hs,
    vs,
    selectors,
    strides,
    rows,
    coefficients,
    levels,
    quantization: Array::make(nc, Array::make(0, 0)),
  }
}

///|
/// T.81 G.2: DC refinement uses two's complement; AC refines signed magnitude.
fn jpg_refine_ac(
  reader : JBR,
  block : Array[Int],
  index : Int,
  bit : Int,
) -> JBR raise Failure {
  let (next, correction) = reader.read_bits(1)
  if correction != 0 {
    block[index] = block[index] + (if block[index] > 0 { bit } else { -bit })
  }
  next
}

///|
fn jpg_progress_ac(
  input : JBR,
  table : JHT,
  block : Array[Int],
  offset : Int,
  first : Int,
  last : Int,
  high : Int,
  low : Int,
  eob : Int,
) -> (JBR, Int) raise Failure {
  let mut reader = input
  let mut run = eob
  let mut k = first
  let bit = 1 << low
  if run == 0 {
    while k <= last {
      let (next, symbol) = jht_decode(table, reader)
      reader = next
      let size = symbol & 15
      let zeros = symbol >> 4
      if size == 0 && zeros != 15 {
        let (next, extra) = reader.read_bits(zeros)
        reader = next
        run = (1 << zeros) + extra
        break
      }
      if high == 0 {
        if size == 0 {
          k = k + 16
          if k > last + 1 {
            raise Failure::Failure("JPEG: progressive zero run exceeds band")
          }
        } else {
          if size > 10 || k + zeros > last {
            raise Failure::Failure("JPEG: progressive AC run exceeds band")
          }
          k = k + zeros
          let (next, value) = reader.read_bits(size)
          reader = next
          let signed = if value < 1 << (size - 1) {
            value - ((1 << size) - 1)
          } else {
            value
          }
          block[offset + zigzag[k]] = signed << low
          k = k + 1
        }
      } else {
        if size > 1 {
          raise Failure::Failure("JPEG: invalid AC refinement category")
        }
        let mut new_value = 0
        if size == 1 {
          let (next, sign) = reader.read_bits(1)
          reader = next
          new_value = if sign == 0 { -bit } else { bit }
        }
        let mut remaining = if size == 0 { 16 } else { zeros }
        let mut complete = false
        while k <= last {
          let index = offset + zigzag[k]
          if block[index] != 0 {
            reader = jpg_refine_ac(reader, block, index, bit)
          } else if remaining > 0 {
            remaining = remaining - 1
            if remaining == 0 && size == 0 {
              k = k + 1
              complete = true
              break
            }
          } else {
            block[index] = new_value
            k = k + 1
            complete = true
            break
          }
          k = k + 1
        }
        if !complete {
          raise Failure::Failure("JPEG: AC refinement run exceeds band")
        }
      }
    }
  }
  if run > 0 {
    if high > 0 {
      while k <= last {
        let index = offset + zigzag[k]
        if block[index] != 0 {
          reader = jpg_refine_ac(reader, block, index, bit)
        }
        k = k + 1
      }
    }
    run = run - 1
  }
  (reader, run)
}

///|
fn jpg_progress_scan(
  state : JPGProgress,
  data : Bytes,
  start : Int,
  end : Int,
  qt : Array[Array[Int]],
  dc_ht : Array[JHT],
  ac_ht : Array[JHT],
  restart_interval : Int,
) -> Int raise Failure {
  if end - start < 6 {
    raise Failure::Failure("JPEG: short progressive scan")
  }
  let count = data[start].to_int()
  let first = data[end - 3].to_int()
  let last = data[end - 2].to_int()
  let high = data[end - 1].to_int() >> 4
  let low = data[end - 1].to_int() & 15
  let nc = state.ids.length()
  if count < 1 ||
    count > nc ||
    end - start != 4 + count * 2 ||
    first > last ||
    last > 63 ||
    (first == 0 && last != 0) ||
    (first > 0 && count != 1) ||
    low > 13 ||
    (high != 0 && high != low + 1) {
    raise Failure::Failure("JPEG: invalid progressive scan parameters")
  }
  let components = Array::make(count, 0)
  let tables = Array::make(count, 0)
  let selected = Array::make(nc, false)
  for sc = 0; sc < count; sc = sc + 1 {
    let id = data[start + 1 + sc * 2].to_int()
    let selectors = data[start + 2 + sc * 2].to_int()
    let dc = selectors >> 4
    let ac = selectors & 15
    let mut ci = -1
    for i = 0; i < nc; i = i + 1 {
      if state.ids[i] == id {
        ci = i
      }
    }
    if ci < 0 || dc > 3 || ac > 3 {
      raise Failure::Failure("JPEG: invalid progressive component selector")
    }
    if selected[ci] || (first > 0 && state.levels[ci][0] < 0) {
      raise Failure::Failure("JPEG: duplicate component or AC before DC")
    }
    selected[ci] = true
    components[sc] = ci
    tables[sc] = if first == 0 { dc } else { ac }
    if (first == 0 && high == 0 && dc_ht[dc].tbl_bits == 0) ||
      (first > 0 && ac_ht[ac].tbl_bits == 0) {
      raise Failure::Failure("JPEG: missing progressive Huffman table")
    }
    if state.quantization[ci].length() == 0 {
      if qt[state.selectors[ci]].length() != 64 {
        raise Failure::Failure("JPEG: missing progressive quantization table")
      }
      state.quantization[ci] = qt[state.selectors[ci]]
    } else if state.quantization[ci] != qt[state.selectors[ci]] {
      // T.81 B.2.4: a component must retain its quantization table across scans.
      raise Failure::Failure(
        "JPEG: quantization changed between progressive scans",
      )
    }
    for k = first; k <= last; k = k + 1 {
      let previous = state.levels[ci][k]
      if (high == 0 && previous != -1) || (high != 0 && previous != high) {
        raise Failure::Failure("JPEG: invalid progressive scan order")
      }
      state.levels[ci][k] = low
    }
  }
  let max_h = state.hs[0]
  let max_v = state.vs[0]
  let ci0 = components[0]
  let mx = if count == 1 {
    (state.width * state.hs[ci0] + max_h * 8 - 1) / (max_h * 8)
  } else {
    (state.width + max_h * 8 - 1) / (max_h * 8)
  }
  let my = if count == 1 {
    (state.height * state.vs[ci0] + max_v * 8 - 1) / (max_v * 8)
  } else {
    (state.height + max_v * 8 - 1) / (max_v * 8)
  }
  let total = mx * my
  let segment_count = if restart_interval > 0 {
    (total - 1) / restart_interval + 1
  } else {
    1
  }
  let (segments, next_marker) = jpg_scan_entropy(
    data, end, restart_interval, segment_count,
  )
  let _ = jpg_segment(data, next_marker)
  if segments.length() != segment_count {
    raise Failure::Failure("JPEG: missing restart marker")
  }
  if first == 0 {
    // Every DC block needs at least one coded bit, including refinement scans.
    // Reject tiny truncated streams before reserving a large coefficient plane.
    let mut blocks_per_mcu = 0
    for ci in components {
      blocks_per_mcu = blocks_per_mcu +
        (if count == 1 { 1 } else { state.hs[ci] * state.vs[ci] })
    }
    for index = 0; index < segments.length(); index = index + 1 {
      let mcus = if restart_interval == 0 {
        total
      } else {
        Int::min(restart_interval, total - index * restart_interval)
      }
      if segments[index].length().to_int64() * 8L <
        mcus.to_int64() * blocks_per_mcu.to_int64() {
        raise Failure::Failure("JPEG: truncated progressive DC scan")
      }
    }
  }
  // Metadata, tables, progression and entropy framing are valid. Allocate only
  // participating components, once, and retain those coefficients across scans.
  for ci in components {
    if state.coefficients[ci].length() == 0 {
      state.coefficients[ci] = Array::make(
        state.strides[ci] * state.rows[ci] * 64,
        0,
      )
    }
  }
  let predictors = Array::make(nc, 0)
  let mut segment = 0
  let mut reader = JBR::new(segments[0])
  let mut eob = 0
  for mcu = 0; mcu < total; mcu = mcu + 1 {
    for sc = 0; sc < count; sc = sc + 1 {
      let ci = components[sc]
      let horizontal = if count == 1 { 1 } else { state.hs[ci] }
      let vertical = if count == 1 { 1 } else { state.vs[ci] }
      for vy = 0; vy < vertical; vy = vy + 1 {
        for vx = 0; vx < horizontal; vx = vx + 1 {
          let bx = mcu % mx * horizontal + vx
          let by = mcu / mx * vertical + vy
          let offset = (by * state.strides[ci] + bx) * 64
          let block = state.coefficients[ci]
          if first == 0 {
            if high == 0 {
              let (next, value, _) = jpg_dc(
                reader,
                dc_ht[tables[sc]],
                predictors[ci],
              )
              reader = next
              predictors[ci] = value
              block[offset] = value << low
            } else {
              let (next, bit) = reader.read_bits(1)
              reader = next
              block[offset] = block[offset] | (bit << low)
            }
          } else {
            let (next, remaining) = jpg_progress_ac(
              reader,
              ac_ht[tables[sc]],
              block,
              offset,
              first,
              last,
              high,
              low,
              eob,
            )
            reader = next
            eob = remaining
          }
        }
      }
    }
    if restart_interval > 0 &&
      (mcu + 1) % restart_interval == 0 &&
      mcu + 1 < total {
      if eob != 0 {
        raise Failure::Failure("JPEG: EOB run crosses restart boundary")
      }
      jpg_finish_segment(reader)
      segment = segment + 1
      if segment >= segments.length() {
        raise Failure::Failure("JPEG: missing restart marker")
      }
      reader = JBR::new(segments[segment])
      for ci = 0; ci < nc; ci = ci + 1 {
        predictors[ci] = 0
      }
    }
  }
  if eob != 0 || segment != segments.length() - 1 {
    raise Failure::Failure("JPEG: excess EOB run or restart marker")
  }
  jpg_finish_segment(reader)
  next_marker
}

///|
fn jpg_progress_image(state : JPGProgress) -> Image raise Failure {
  let nc = state.ids.length()
  let widths = Array::make(nc, 0)
  let planes = Array::make(nc, Array::make(0, b'\x00'))
  let block = Array::make(64, 0)
  for ci = 0; ci < nc; ci = ci + 1 {
    if state.levels[ci][0] < 0 {
      raise Failure::Failure("JPEG: progressive component has no DC scan")
    }
    widths[ci] = state.strides[ci] * 8
    planes[ci] = Array::make(widths[ci] * state.rows[ci] * 8, b'\x00')
    for by = 0; by < state.rows[ci]; by = by + 1 {
      for bx = 0; bx < state.strides[ci]; bx = bx + 1 {
        let offset = (by * state.strides[ci] + bx) * 64
        for k = 0; k < 64; k = k + 1 {
          let value = state.coefficients[ci][offset + k]
          // Bound dequantization and IDCT on malformed high-approximation data.
          if value < -32768 || value > 32767 {
            raise Failure::Failure("JPEG: progressive coefficient out of range")
          }
          block[k] = value * state.quantization[ci][k]
        }
        let pixels = idct_2d(block)
        for y = 0; y < 8; y = y + 1 {
          for x = 0; x < 8; x = x + 1 {
            planes[ci][(by * 8 + y) * widths[ci] + bx * 8 + x] = pixels[y * 8 +
            x].to_byte()
          }
        }
      }
    }
  }
  let w = state.width
  let h = state.height
  let max_h = state.hs[0]
  let max_v = state.vs[0]
  let chroma_w = (w + max_h - 1) / max_h
  let chroma_h = (h + max_v - 1) / max_v
  let out = Array::make(checked_image_size(w, h, nc), b'\x00')
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      if nc == 1 {
        out[y * w + x] = planes[0][y * widths[0] + x]
      } else {
        let (r, g, b) = ycbcr_to_rgb(
          planes[0][y * widths[0] + x].to_int(),
          jpg_chroma(
            planes[1],
            widths[1],
            chroma_w,
            chroma_h,
            x,
            y,
            max_h,
            max_v,
          ),
          jpg_chroma(
            planes[2],
            widths[2],
            chroma_w,
            chroma_h,
            x,
            y,
            max_h,
            max_v,
          ),
        )
        let offset = (y * w + x) * 3
        out[offset] = r.to_byte()
        out[offset + 1] = g.to_byte()
        out[offset + 2] = b.to_byte()
      }
    }
  }
  Image::new(
    w,
    h,
    if nc == 1 {
      PixelFormat::Gray8
    } else {
      PixelFormat::RGB8
    },
    Bytes::from_array(out),
  )
}
