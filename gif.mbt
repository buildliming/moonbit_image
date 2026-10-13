// Copyright (c) 2025 lws
// GIF (Graphics Interchange Format) decoder
//
// Supports GIF87a and GIF89a formats with:
//   - LZW decompression with variable-length codes (up to 12 bits)
//   - Global and local color tables
//   - 4-pass interlacing
//   - Transparency via Graphic Control Extension
//   - Single-frame decoding (returns first image)
//
// Performance optimizations:
//   - LZW state inlined into mutable locals (no per-code struct allocation)
//   - Color tables pre-computed as RGBA byte quads (no per-pixel .to_byte())
//   - Non-interlaced fast path (no row_map indirection)
//   - Stack array allocated once and reused
//   - Bulk byte reading when bit-aligned

//-----------------------------------------------------------------------------
// LZW Decompressor for GIF (inlined, zero struct allocation)
//-----------------------------------------------------------------------------

///|
/// Decode LZW stream into raw pixel indices
/// Uses mutable locals for LZW state to eliminate struct allocation overhead.
/// For a 256x256 image, this avoids ~65,000 struct allocations.
fn lzw_decompress(
  data : Bytes,
  min_code_size : Int,
  pixel_count : Int,
) -> Array[Byte] raise Failure {
  if min_code_size < 2 || min_code_size > 8 {
    raise Failure::Failure("GIF: invalid LZW code size")
  }
  let max_table = 4096
  let clear_code = 1 << min_code_size
  let eoi_code = clear_code + 1
  let table_prefix = Array::make(max_table, 0)
  let table_suffix = Array::make(max_table, 0)
  let stack = Array::make(max_table, b'\x00')
  let pixels = Array::make(pixel_count, b'\x00')
  let mut pi = 0
  let mut pos = 0
  let mut bit_pos = 0
  let mut code_size = min_code_size + 1
  let mut next_code = eoi_code + 1
  let mut max_code = (1 << code_size) - 1
  let mut prev = -1
  while true {
    let (next_pos, next_bit_pos, code) = lzw_read_code(
      data, pos, bit_pos, code_size,
    )
    pos = next_pos
    bit_pos = next_bit_pos
    if code == clear_code {
      next_code = eoi_code + 1
      code_size = min_code_size + 1
      max_code = (1 << code_size) - 1
      prev = -1
      continue
    }
    if code == eoi_code {
      if pi != pixel_count {
        raise Failure::Failure("GIF: incorrect LZW pixel count")
      }
      let consumed = pos + (if bit_pos > 0 { 1 } else { 0 })
      if consumed != data.length() {
        raise Failure::Failure("GIF: excess data after LZW end code")
      }
      return pixels
    }
    if prev < 0 {
      if code >= clear_code {
        raise Failure::Failure("GIF: invalid first LZW code")
      }
      if pi >= pixel_count {
        raise Failure::Failure("GIF: excess LZW pixels")
      }
      pixels[pi] = code.to_byte()
      pi = pi + 1
    } else {
      let (new_size, new_next, new_max, count) = lzw_decode_string(
        table_prefix, table_suffix, stack, code, prev, eoi_code, code_size, next_code,
        max_code,
      )
      code_size = new_size
      next_code = new_next
      max_code = new_max
      if count > pixel_count - pi {
        raise Failure::Failure("GIF: excess LZW pixels")
      }
      for i = 0; i < count; i = i + 1 {
        pixels[pi] = stack[count - 1 - i]
        pi = pi + 1
      }
    }
    prev = code
  }
  raise Failure::Failure("GIF: missing LZW end code")
}

///|
/// Read the next variable-length code from the LZW bitstream (LSB-first).
/// Returns (new_pos, new_bit_pos, code).
/// Uses bulk byte reading when byte-aligned for codes >= 8 bits.
fn lzw_read_code(
  data : Bytes,
  pos : Int,
  bit_pos : Int,
  code_size : Int,
) -> (Int, Int, Int) raise Failure {
  let mut byte_pos = pos
  let mut bp = bit_pos
  let mut result = 0
  let mut bit_count = 0

  // Fast path: byte-aligned and reading 8+ bits -> read two bytes at once
  if bp == 0 && code_size >= 8 && byte_pos + 1 < data.length() {
    let lo = data[byte_pos].to_int()
    let hi = data[byte_pos + 1].to_int()
    let word = lo | (hi << 8)
    result = word & ((1 << code_size) - 1)
    let bits_read = if code_size <= 16 { code_size } else { 16 }
    byte_pos = byte_pos + bits_read / 8
    bp = bits_read % 8
    return (byte_pos, bp, result)
  }

  // General path: bit-by-bit
  while bit_count < code_size {
    if byte_pos >= data.length() {
      raise Failure::Failure("GIF: unexpected end of LZW data")
    }
    let byte = data[byte_pos].to_int()
    let bits_left = 8 - bp
    let needed = code_size - bit_count
    let take = if needed < bits_left { needed } else { bits_left }
    let val = (byte >> bp) & ((1 << take) - 1)
    result = result | (val << bit_count)
    bit_count = bit_count + take
    if take == bits_left {
      byte_pos = byte_pos + 1
      bp = 0
    } else {
      bp = bp + take
    }
  }

  (byte_pos, bp, result)
}

///|
/// Decode a single LZW code's output string, building it on the stack.
/// Returns (new_code_size, new_next_code, new_max_code, output_length).
/// The output is placed on `stack` in reverse order (pop from end to get forward order).
/// This function handles both the normal case and the KwKwK edge case correctly:
/// when `code == next_code`, output = string(prev_code) + first_char(string(prev_code)).
fn lzw_decode_string(
  table_prefix : Array[Int],
  table_suffix : Array[Int],
  stack : Array[Byte],
  code : Int,
  prev_code : Int,
  eoi_code : Int,
  code_size : Int,
  next_code : Int,
  max_code : Int,
) -> (Int, Int, Int, Int) raise Failure {
  let max_table = table_prefix.length()
  let mut c = code
  let mut sp = 0

  // KwKwK case: code not yet in table.
  // Output = string(prev_code) + first_char(string(prev_code)).
  // We must trace prev_code to find its first character, then push it.
  if c == next_code {
    // Find first character of prev_code's string by tracing to root
    let mut t = prev_code
    while t > eoi_code {
      if t >= max_table {
        raise Failure::Failure("GIF: invalid LZW prefix chain")
      }
      t = table_prefix[t]
    }
    stack[sp] = t.to_byte()
    sp = sp + 1
    c = prev_code
  }

  // Walk prefix chain: push suffix bytes onto stack
  while c > eoi_code {
    if c >= next_code || c >= max_table {
      raise Failure::Failure("GIF: invalid LZW code \{c}")
    }
    stack[sp] = table_suffix[c].to_byte()
    sp = sp + 1
    c = table_prefix[c]
  }
  // Root code (c <= eoi_code, the root value is the actual pixel index)
  stack[sp] = c.to_byte()
  sp = sp + 1

  // First byte of output (bottom of stack = first character of decoded string)
  let first = stack[sp - 1].to_int()

  // Add new entry: prev_code + first_byte
  let mut new_next = next_code
  let mut new_cs = code_size
  let mut new_max = max_code

  if next_code < max_table {
    table_prefix[next_code] = prev_code
    table_suffix[next_code] = first
    new_next = next_code + 1
    // Grow code size if needed
    if new_next > max_code && code_size < 12 {
      new_cs = code_size + 1
      new_max = (1 << new_cs) - 1
    }
  }

  (new_cs, new_next, new_max, sp)
}

//-----------------------------------------------------------------------------
// GIF Decoder
//-----------------------------------------------------------------------------

///|
/// Decode a GIF image from raw bytes (returns the first frame)
pub fn decode_gif(data : Bytes) -> Image raise Failure {
  let decoder = GifDecoder::new(data)
  decoder.decode()
}

///|
/// GIF decoder state
priv struct GifDecoder {
  data : Bytes
  pos : Int
  width : Int
  height : Int
  global_ct : Array[(Int, Int, Int)] // (R, G, B) tuples
  bg_color : Int
}

///|
fn GifDecoder::new(data : Bytes) -> GifDecoder raise Failure {
  // Check signature
  if data.length() < 13 {
    raise Failure::Failure("GIF: file too small")
  }

  // "GIF" signature
  if data[0] != b'G' || data[1] != b'I' || data[2] != b'F' {
    raise Failure::Failure("GIF: invalid signature")
  }

  // Version: "87a" or "89a"
  if data[3] != b'8' || (data[4] != b'7' && data[4] != b'9') || data[5] != b'a' {
    raise Failure::Failure("GIF: unsupported version")
  }

  // Logical Screen Descriptor
  let w = read_u16_le(data, 6)
  let h = read_u16_le(data, 8)
  let packed = data[10].to_int()
  let bg = data[11].to_int()
  let _aspect = data[12].to_int()

  let _ = checked_image_size(w, h, 4)

  let has_gct = packed >> 7 != 0
  let gct_size = 1 << ((packed & 7) + 1)

  // Read Global Color Table if present
  let mut gct = Array::make(0, (0, 0, 0))
  let mut pos = 13
  if has_gct {
    if gct_size * 3 > data.length() - pos {
      raise Failure::Failure("GIF: truncated global palette")
    }
    if bg >= gct_size {
      raise Failure::Failure("GIF: background index out of range")
    }
    gct = Array::make(gct_size, (0, 0, 0))
    for i = 0; i < gct_size; i = i + 1 {
      let r = data[pos].to_int()
      let g = data[pos + 1].to_int()
      let b = data[pos + 2].to_int()
      gct[i] = (r, g, b)
      pos = pos + 3
    }
  }

  { data, pos, width: w, height: h, global_ct: gct, bg_color: bg, }
}

///|
/// Read a sub-block chain (GIF data sub-blocks)
/// Each sub-block: 1-byte count (0-255) followed by count bytes of data
/// Terminated by a 0-byte count
fn read_sub_blocks(
  data : Bytes,
  start_pos : Int,
  keep? : Bool = true,
) -> (Bytes, Int) raise Failure {
  let buf = Buffer()
  let mut pos = start_pos
  while pos < data.length() {
    let count = data[pos].to_int()
    pos = pos + 1
    if count == 0 {
      return (buf.to_bytes(), pos)
    }
    if count > data.length() - pos {
      raise Failure::Failure("GIF: truncated sub-block")
    }
    if keep {
      if count > MAX_DECODE_BYTES - buf.length() {
        raise Failure::Failure("GIF: compressed data exceeds size limit")
      }
      buf.write_bytes(data[pos:pos + count].to_owned())
    }
    pos = pos + count
  }
  raise Failure::Failure("GIF: missing sub-block terminator")
}

///|
/// Build interlace row mapping for 4-pass interlacing
/// Returns an array mapping source row index to destination row
fn build_interlace_map(img_h : Int) -> Array[Int] {
  let row_map = Array::make(img_h, 0)
  let mut ri = 0
  // Pass 1: every 8th row starting at 0
  let mut r = 0
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 8
  }
  // Pass 2: every 8th row starting at 4
  r = 4
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 8
  }
  // Pass 3: every 4th row starting at 2
  r = 2
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 4
  }
  // Pass 4: every 2nd row starting at 1
  r = 1
  while r < img_h {
    row_map[ri] = r
    ri = ri + 1
    r = r + 2
  }
  row_map
}

///|
/// Pre-compute color table as RGBA byte quads for fast pixel writes.
/// Converts (Int,Int,Int) tuples to [r_byte, g_byte, b_byte, a_byte] arrays,
/// eliminating per-pixel .to_byte() calls and tuple destructuring.
fn ct_to_rgba(ct : Array[(Int, Int, Int)]) -> Array[Array[Byte]] {
  let n = ct.length()
  let result = Array::make(n, [b'\x00', b'\x00', b'\x00', b'\xFF'])
  for i = 0; i < n; i = i + 1 {
    let (r, g, b) = ct[i]
    result[i] = [r.to_byte(), g.to_byte(), b.to_byte(), b'\xFF']
  }
  result
}

///|
/// Decode the first displayed canvas without parsing later animation frames.
fn GifDecoder::decode(self : GifDecoder) -> Image raise Failure {
  self.decode_all(first_only=true).frames[0]
}

///|
/// Decode all composited GIF frames. Delays are in hundredths of a second.
pub fn decode_gif_all(data : Bytes) -> AnimatedImage raise Failure {
  GifDecoder::new(data).decode_all()
}

///|
fn GifDecoder::decode_all(
  self : GifDecoder,
  first_only? : Bool = false,
) -> AnimatedImage raise Failure {
  let mut pos = self.pos
  let mut loop_count = 0
  let frames : Array[Image] = []
  let delays : Array[Int] = []
  let mut transparent_idx = -1
  let mut delay = 0
  let mut disposal = 0
  let canvas_size = checked_image_size(self.width, self.height, 4)
  let mut canvas : Array[Byte] = []
  let background = if self.global_ct.length() > 0 {
    let (r, g, b) = self.global_ct[self.bg_color]
    [r.to_byte(), g.to_byte(), b.to_byte(), b'\xFF']
  } else {
    [b'\x00', b'\x00', b'\x00', b'\x00']
  }
  let mut has_trailer = false
  while pos < self.data.length() {
    let block = self.data[pos].to_int()
    pos = pos + 1
    if block == 0x3B {
      has_trailer = true
      break
    }
    if block == 0x21 {
      if pos >= self.data.length() {
        raise Failure::Failure("GIF: truncated extension")
      }
      let label = self.data[pos].to_int()
      pos = pos + 1
      if label == 0xF9 {
        if self.data.length() - pos < 6 {
          raise Failure::Failure("GIF: truncated GCE")
        }
        if self.data[pos] != b'\x04' || self.data[pos + 5] != b'\x00' {
          raise Failure::Failure("GIF: invalid GCE size or terminator")
        }
        let packed = self.data[pos + 1].to_int()
        disposal = (packed >> 2) & 7
        if disposal > 3 {
          raise Failure::Failure("GIF: unsupported disposal method")
        }
        delay = read_u16_le(self.data, pos + 2)
        transparent_idx = if (packed & 1) != 0 {
          self.data[pos + 4].to_int()
        } else {
          -1
        }
        pos = pos + 6
      } else if label == 0xFF {
        if self.data.length() - pos < 12 || self.data[pos] != b'\x0B' {
          raise Failure::Failure("GIF: invalid application extension")
        }
        let application = self.data[pos + 1:pos + 12].to_owned()
        pos = pos + 12
        let is_loop = application == b"NETSCAPE2.0" ||
          application == b"ANIMEXTS1.0"
        let (payload, next_pos) = read_sub_blocks(self.data, pos, keep=is_loop)
        pos = next_pos
        if is_loop && payload.length() >= 3 && payload[0] == b'\x01' {
          loop_count = read_u16_le(payload, 1)
        }
      } else {
        if label == 0x01 {
          raise Failure::Failure("GIF: plain text rendering is not supported")
        }
        let (_, next_pos) = read_sub_blocks(self.data, pos, keep=false)
        pos = next_pos
      }
      continue
    }
    if block != 0x2C {
      raise Failure::Failure("GIF: unknown block type")
    }
    if self.data.length() - pos < 9 {
      raise Failure::Failure("GIF: truncated image descriptor")
    }
    let left = read_u16_le(self.data, pos)
    let top = read_u16_le(self.data, pos + 2)
    let width = read_u16_le(self.data, pos + 4)
    let height = read_u16_le(self.data, pos + 6)
    let packed = self.data[pos + 8].to_int()
    pos = pos + 9
    let pixel_count = checked_image_size(width, height, 1)
    if left > self.width - width || top > self.height - height {
      raise Failure::Failure("GIF: image rectangle exceeds logical screen")
    }
    if frames.length() >= MAX_DECODE_BYTES / canvas_size {
      raise Failure::Failure("GIF: cumulative frames exceed 256 MiB limit")
    }
    let mut colors = self.global_ct
    if (packed & 0x80) != 0 {
      let count = 1 << ((packed & 7) + 1)
      if count * 3 > self.data.length() - pos {
        raise Failure::Failure("GIF: truncated local palette")
      }
      colors = Array::make(count, (0, 0, 0))
      for i = 0; i < count; i = i + 1 {
        colors[i] = (
          self.data[pos].to_int(),
          self.data[pos + 1].to_int(),
          self.data[pos + 2].to_int(),
        )
        pos = pos + 3
      }
    }
    if colors.length() == 0 {
      raise Failure::Failure("GIF: missing color table")
    }
    let palette = ct_to_rgba(colors)
    if pos >= self.data.length() {
      raise Failure::Failure("GIF: missing LZW code size")
    }
    let min_code_size = self.data[pos].to_int()
    if min_code_size < 2 || min_code_size > 8 {
      raise Failure::Failure("GIF: invalid LZW code size")
    }
    pos = pos + 1
    let (compressed, next_pos) = read_sub_blocks(self.data, pos)
    pos = next_pos
    let indices = lzw_decompress(compressed, min_code_size, pixel_count)
    // A transparent initial canvas and background disposal use the transparent
    // palette color; subsequent transparent samples preserve existing pixels.
    let clear = if transparent_idx >= 0 {
      if transparent_idx < palette.length() {
        let color = palette[transparent_idx]
        [color[0], color[1], color[2], b'\x00']
      } else {
        [b'\x00', b'\x00', b'\x00', b'\x00']
      }
    } else {
      background
    }
    if frames.length() == 0 {
      canvas = Array::make(canvas_size, b'\x00')
      for i = 0; i < canvas_size; i = i + 1 {
        canvas[i] = clear[i % 4]
      }
    }
    let previous = if disposal == 3 && !first_only {
      let saved = Array::make(pixel_count * 4, b'\x00')
      for y = 0; y < height; y = y + 1 {
        for x = 0; x < width * 4; x = x + 1 {
          saved[y * width * 4 + x] = canvas[((top + y) * self.width + left) * 4 +
            x]
        }
      }
      saved
    } else {
      []
    }
    let rows = if (packed & 0x40) != 0 {
      build_interlace_map(height)
    } else {
      []
    }
    for y = 0; y < height; y = y + 1 {
      let target_y = top + (if rows.length() > 0 { rows[y] } else { y })
      for x = 0; x < width; x = x + 1 {
        let index = indices[y * width + x].to_int()
        if index == transparent_idx {
          continue
        }
        if index >= palette.length() {
          raise Failure::Failure("GIF: palette index out of range")
        }
        let offset = (target_y * self.width + left + x) * 4
        let color = palette[index]
        for channel = 0; channel < 4; channel = channel + 1 {
          canvas[offset + channel] = color[channel]
        }
      }
    }
    // Store each completed canvas once instead of concatenating then recopying
    // every frame at the end of the animation.
    let snapshot = Array::make(canvas_size, b'\x00')
    for i = 0; i < canvas_size; i = i + 1 {
      snapshot[i] = canvas[i]
    }
    frames.push(
      Image::new(
        self.width,
        self.height,
        PixelFormat::RGBA8,
        Bytes::from_array(snapshot),
      ),
    )
    delays.push(delay)
    if first_only {
      return AnimatedImage::new(
        frames,
        delays,
        self.width,
        self.height,
        loop_count,
      )
    }
    // Disposal belongs to the frame just displayed and affects only its area.
    if disposal == 2 || disposal == 3 {
      for y = 0; y < height; y = y + 1 {
        for x = 0; x < width * 4; x = x + 1 {
          let value = if disposal == 3 {
            previous[y * width * 4 + x]
          } else {
            clear[x % 4]
          }
          canvas[((top + y) * self.width + left) * 4 + x] = value
        }
      }
    }
    transparent_idx = -1
    delay = 0
    disposal = 0
  }
  if !has_trailer {
    raise Failure::Failure("GIF: missing trailer")
  }
  if frames.length() == 0 {
    raise Failure::Failure("GIF: no frames found")
  }
  AnimatedImage::new(frames, delays, self.width, self.height, loop_count)
}
