// Copyright (c) 2025 lws
// GIF (Graphics Interchange Format) decoder
//
// Supports GIF87a and GIF89a formats with:
//   - LZW decompression with variable-length codes (up to 12 bits)
//   - Global and local color tables
//   - 4-pass interlacing
//   - Transparency via Graphic Control Extension
//   - Single-frame decoding (returns first image)

//-----------------------------------------------------------------------------
// LZW Decoder for GIF
//-----------------------------------------------------------------------------

/// LZW decoder state for GIF sub-block data streams
/// GIF LZW uses variable-length codes starting at min_code_size+1 bits,
/// growing as the string table fills, resetting on Clear Code.
priv struct LzwDecoder {
  data : Bytes          // concatenated sub-block data
  pos : Int             // byte position in data
  bit_pos : Int         // bit position within current byte (0=LSB)
  min_code_size : Int   // minimum code size from GIF header
  code_size : Int       // current code size in bits
  clear_code : Int      // code that resets the table
  eoi_code : Int        // end of information code
  next_code : Int       // next available code slot
  max_code : Int        // maximum code for current code_size
  table_prefix : Array[Int]  // prefix code for each entry
  table_suffix : Array[Int]  // suffix byte for each entry
}

fn LzwDecoder::new(data : Bytes, min_code_size : Int) -> LzwDecoder {
  let clear = 1 << min_code_size
  let eoi = clear + 1
  let max_table = 4096  // max 12-bit codes
  {
    data: data, pos: 0, bit_pos: 0,
    min_code_size: min_code_size,
    code_size: min_code_size + 1,
    clear_code: clear, eoi_code: eoi,
    next_code: eoi + 1,
    max_code: (1 << (min_code_size + 1)) - 1,
    table_prefix: Array::make(max_table, 0),
    table_suffix: Array::make(max_table, 0)
  }
}

/// Reset the string table to initial state
fn LzwDecoder::reset(self : LzwDecoder) -> LzwDecoder {
  let max_table = self.table_prefix.length()
  {
    data: self.data, pos: self.pos, bit_pos: self.bit_pos,
    min_code_size: self.min_code_size,
    code_size: self.min_code_size + 1,
    clear_code: self.clear_code, eoi_code: self.eoi_code,
    next_code: self.eoi_code + 1,
    max_code: (1 << (self.min_code_size + 1)) - 1,
    table_prefix: Array::make(max_table, 0),
    table_suffix: Array::make(max_table, 0)
  }
}

/// Add a new entry to the string table, growing code_size if needed
fn LzwDecoder::add_entry(self : LzwDecoder, prefix : Int, suffix : Int) -> LzwDecoder {
  let idx = self.next_code
  if idx < self.table_prefix.length() {
    self.table_prefix[idx] = prefix
    self.table_suffix[idx] = suffix
  }
  let next = idx + 1
  // Grow code size if table is about to exceed current max
  let mut new_code_size = self.code_size
  let mut new_max = self.max_code
  if next > self.max_code && self.code_size < 12 {
    new_code_size = self.code_size + 1
    new_max = (1 << new_code_size) - 1
  }
  {
    data: self.data, pos: self.pos, bit_pos: self.bit_pos,
    min_code_size: self.min_code_size,
    code_size: new_code_size,
    clear_code: self.clear_code, eoi_code: self.eoi_code,
    next_code: next,
    max_code: new_max,
    table_prefix: self.table_prefix, table_suffix: self.table_suffix
  }
}

/// Read the next variable-length code from the bitstream (LSB-first)
fn LzwDecoder::read_code(self : LzwDecoder) -> (LzwDecoder, Int) raise Failure {
  let cs = self.code_size
  let mut result = 0
  let mut bit_count = 0
  let mut byte_pos = self.pos
  let mut bit_pos = self.bit_pos

  while bit_count < cs {
    if byte_pos >= self.data.length() {
      raise Failure::Failure("GIF: unexpected end of LZW data")
    }
    let byte = self.data[byte_pos].to_int()
    let bits_left = 8 - bit_pos
    let needed = cs - bit_count
    let take = if needed < bits_left { needed } else { bits_left }
    let val = (byte >> bit_pos) & ((1 << take) - 1)
    result = result | (val << bit_count)
    bit_count = bit_count + take
    if take == bits_left {
      byte_pos = byte_pos + 1
      bit_pos = 0
    } else {
      bit_pos = bit_pos + take
    }
  }

  let new_decoder = {
    data: self.data, pos: byte_pos, bit_pos: bit_pos,
    min_code_size: self.min_code_size,
    code_size: self.code_size,
    clear_code: self.clear_code, eoi_code: self.eoi_code,
    next_code: self.next_code,
    max_code: self.max_code,
    table_prefix: self.table_prefix, table_suffix: self.table_suffix
  }
  (new_decoder, result)
}

/// Decode a single code's output string and add it to the table
/// Returns (new_decoder, output_bytes, first_byte_of_output)
fn LzwDecoder::decode_and_add(
  self : LzwDecoder,
  code : Int,
  prev_code : Int
) -> (LzwDecoder, Array[Byte], Int) raise Failure {
  let stack = Array::make(4096, b'\x00')
  let mut sp = 0
  let mut c = code

  // Build the string: follow prefix chain
  if c == self.next_code {
    // KwKwK case: code not yet in table
    stack[sp] = prev_code.to_byte()  // placeholder, will fix after tracing prev
    sp = sp + 1
    c = prev_code
  }

  while c > self.eoi_code {
    if c >= self.next_code || c >= self.table_prefix.length() {
      raise Failure::Failure("GIF: invalid LZW code")
    }
    stack[sp] = self.table_suffix[c].to_byte()
    sp = sp + 1
    c = self.table_prefix[c]
  }
  // Root code: the suffix for codes < clear_code is the code itself
  let root_byte = c.to_byte()
  stack[sp] = root_byte
  sp = sp + 1

  // First byte of output (bottom of stack)
  let first = stack[sp - 1].to_int()

  // Reverse stack to get output in correct order
  let out_len = sp
  let out = Array::make(out_len, b'\x00')
  for i = 0; i < out_len; i = i + 1 {
    out[i] = stack[out_len - 1 - i]
  }

  // Add new entry: prev_code + first_byte
  let mut dec = self
  if self.next_code < 4096 {
    dec = self.add_entry(prev_code, first)
  }

  (dec, out, first)
}

/// Decode LZW stream into raw pixel indices
fn lzw_decompress(data : Bytes, min_code_size : Int, pixel_count : Int) -> Array[Byte] raise Failure {
  let mut d = LzwDecoder::new(data, min_code_size)
  let pixels = Array::make(pixel_count, b'\x00')
  let mut pi = 0

  // Read first code
  let (d2, code) = d.read_code()
  d = d2

  if code == d.clear_code {
    // Shouldn't happen as first code, but handle gracefully
    d = d.reset()
    let (d3, code2) = d.read_code()
    d = d3
    if code2 == d.eoi_code { return pixels }
    // Output root code
    if pi < pixel_count {
      pixels[pi] = code2.to_byte()
      pi = pi + 1
    }
  } else if code != d.eoi_code {
    // Output root code
    if pi < pixel_count {
      pixels[pi] = code.to_byte()
      pi = pi + 1
    }
  } else {
    return pixels
  }

  let mut prev = code

  while pi < pixel_count {
    let (d3, code2) = d.read_code()
    d = d3

    if code2 == d.eoi_code {
      break
    }

    if code2 == d.clear_code {
      d = d.reset()
      // After clear, read next code
      let (d4, code3) = d.read_code()
      d = d4
      if code3 == d.eoi_code { break }
      if pi < pixel_count {
        pixels[pi] = code3.to_byte()
        pi = pi + 1
      }
      prev = code3
      continue
    }

    let (d4, out, _) = d.decode_and_add(code2, prev)
    d = d4

    // Copy output bytes to pixel buffer
    for j = 0; j < out.length() && pi < pixel_count; j = j + 1 {
      pixels[pi] = out[j]
      pi = pi + 1
    }

    prev = code2
  }

  pixels
}

//-----------------------------------------------------------------------------
// GIF Decoder
//-----------------------------------------------------------------------------

/// Decode a GIF image from raw bytes
pub fn decode_gif(data : Bytes) -> Image raise Failure {
  let decoder = GifDecoder::new(data)
  decoder.decode()
}

/// GIF decoder state
priv struct GifDecoder {
  data : Bytes
  pos : Int
  width : Int
  height : Int
  global_ct : Array[(Int, Int, Int)]  // (R, G, B) tuples stored as flat arrays
  bg_color : Int
  transparent_idx : Int
  has_transparency : Bool
  delay : Int  // in centiseconds
}

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

  if w <= 0 || h <= 0 {
    raise Failure::Failure("GIF: invalid dimensions")
  }

  let has_gct = (packed >> 7) != 0
  let gct_size = 1 << ((packed & 7) + 1)

  // Read Global Color Table if present
  let mut gct = Array::make(0, (0, 0, 0))
  let mut pos = 13
  if has_gct {
    gct = Array::make(gct_size, (0, 0, 0))
    for i = 0; i < gct_size; i = i + 1 {
      let r = data[pos].to_int()
      let g = data[pos + 1].to_int()
      let b = data[pos + 2].to_int()
      gct[i] = (r, g, b)
      pos = pos + 3
    }
  }

  {
    data: data, pos: pos, width: w, height: h,
    global_ct: gct, bg_color: bg,
    transparent_idx: -1, has_transparency: false,
    delay: 0
  }
}

/// Read a sub-block chain (GIF data sub-blocks)
/// Each sub-block: 1-byte count (0-255) followed by count bytes of data
/// Terminated by a 0-byte count
fn read_sub_blocks(data : Bytes, start_pos : Int) -> (Bytes, Int) raise Failure {
  let buf = Buffer()
  let mut pos = start_pos
  while pos < data.length() {
    let count = data[pos].to_int()
    pos = pos + 1
    if count == 0 { break }
    if pos + count > data.length() {
      raise Failure::Failure("GIF: truncated sub-block")
    }
    buf.write_bytes(data[pos:pos + count].to_owned())
    pos = pos + count
  }
  (buf.to_bytes(), pos)
}

/// Decode a single GIF frame
fn GifDecoder::decode(self : GifDecoder) -> Image raise Failure {
  let mut dec = self
  let mut pos = dec.pos

  // Skip extensions and find Image Descriptor
  while pos < dec.data.length() {
    let block_type = dec.data[pos].to_int()
    pos = pos + 1

    // Extension block
    if block_type == 0x21 {
      if pos >= dec.data.length() {
        raise Failure::Failure("GIF: truncated extension")
      }
      let ext_type = dec.data[pos].to_int()
      pos = pos + 1

      if ext_type == 0xF9 {
        // Graphic Control Extension
        if pos + 5 > dec.data.length() {
          raise Failure::Failure("GIF: truncated GCE")
        }
        let _block_size = dec.data[pos].to_int()  // should be 4
        pos = pos + 1
        let gce_packed = dec.data[pos].to_int()
        pos = pos + 1
        let delay = read_u16_le(dec.data, pos)
        pos = pos + 2
        let trans_idx = dec.data[pos].to_int()
        pos = pos + 1
        let _term = dec.data[pos].to_int()  // block terminator 0x00
        pos = pos + 1

        let has_trans = (gce_packed & 1) != 0
        dec = {
          data: dec.data, pos: pos, width: dec.width, height: dec.height,
          global_ct: dec.global_ct, bg_color: dec.bg_color,
          transparent_idx: if has_trans { trans_idx } else { -1 },
          has_transparency: has_trans,
          delay: delay
        }
      } else {
        // Skip other extensions (comment, plain text, application)
        // Read and discard sub-blocks
        let (_bs, np) = read_sub_blocks(dec.data, pos)
        pos = np
      }
      continue
    }

    // Image Descriptor
    if block_type == 0x2C {
      // Parse image descriptor
      if pos + 9 > dec.data.length() {
        raise Failure::Failure("GIF: truncated image descriptor")
      }
      let _img_left = read_u16_le(dec.data, pos)
      let _img_top = read_u16_le(dec.data, pos + 2)
      let img_w = read_u16_le(dec.data, pos + 4)
      let img_h = read_u16_le(dec.data, pos + 6)
      let img_packed = dec.data[pos + 8].to_int()
      pos = pos + 9

      let has_lct = (img_packed >> 7) != 0
      let is_interlaced = ((img_packed >> 6) & 1) != 0
      let lct_size = 1 << ((img_packed & 7) + 1)

      // Read Local Color Table if present
      let mut active_ct = dec.global_ct
      if has_lct {
        active_ct = Array::make(lct_size, (0, 0, 0))
        for i = 0; i < lct_size; i = i + 1 {
          let r = dec.data[pos].to_int()
          let g = dec.data[pos + 1].to_int()
          let b = dec.data[pos + 2].to_int()
          active_ct[i] = (r, g, b)
          pos = pos + 3
        }
      }

      // Read LZW minimum code size
      if pos >= dec.data.length() {
        raise Failure::Failure("GIF: no LZW code size")
      }
      let min_code_size = dec.data[pos].to_int()
      if min_code_size < 2 {
        raise Failure::Failure("GIF: invalid LZW code size")
      }
      pos = pos + 1

      // Read sub-blocks containing LZW data
      let (lzw_data, np) = read_sub_blocks(dec.data, pos)
      pos = np

      // Decompress LZW data
      let pixel_count = img_w * img_h
      let indices = lzw_decompress(lzw_data, min_code_size, pixel_count)

      // Build output image
      let out_w = dec.width
      let out_h = dec.height
      let out_size = out_w * out_h * 4
      let out = Array::make(out_size, b'\x00')

      // Build interlace row mapping
      let row_map = Array::make(img_h, 0)
      if is_interlaced {
        let mut ri = 0
        // Pass 1: every 8th row starting at 0
        let mut r = 0
        while r < img_h { row_map[ri] = r; ri = ri + 1; r = r + 8 }
        // Pass 2: every 8th row starting at 4
        r = 4
        while r < img_h { row_map[ri] = r; ri = ri + 1; r = r + 8 }
        // Pass 3: every 4th row starting at 2
        r = 2
        while r < img_h { row_map[ri] = r; ri = ri + 1; r = r + 4 }
        // Pass 4: every 2nd row starting at 1
        r = 1
        while r < img_h { row_map[ri] = r; ri = ri + 1; r = r + 2 }
      } else {
        for r = 0; r < img_h; r = r + 1 { row_map[r] = r }
      }

      // Fill output with RGBA pixels
      for y = 0; y < img_h; y = y + 1 {
        let src_row = y
        let dst_row = row_map[src_row]
        for x = 0; x < img_w; x = x + 1 {
          let idx = indices[src_row * img_w + x].to_int()
          if dec.has_transparency && idx == dec.transparent_idx {
            // Transparent pixel
            let di = (dst_row * out_w + x) * 4
            out[di] = b'\x00'
            out[di + 1] = b'\x00'
            out[di + 2] = b'\x00'
            out[di + 3] = b'\x00'
          } else if idx < active_ct.length() {
            let (r_val, g_val, b_val) = active_ct[idx]
            let di = (dst_row * out_w + x) * 4
            out[di] = r_val.to_byte()
            out[di + 1] = g_val.to_byte()
            out[di + 2] = b_val.to_byte()
            out[di + 3] = b'\xFF'
          } else {
            // Out of bounds index: use black
            let di = (dst_row * out_w + x) * 4
            out[di] = b'\x00'
            out[di + 1] = b'\x00'
            out[di + 2] = b'\x00'
            out[di + 3] = b'\xFF'
          }
        }
      }

      return Image::new(out_w, out_h, PixelFormat::RGBA8, Bytes::from_array(out))
    }

    // Trailer: end of file
    if block_type == 0x3B {
      raise Failure::Failure("GIF: no image found")
    }

    raise Failure::Failure("GIF: unknown block type 0x\{block_type.to_byte()}")
  }

  raise Failure::Failure("GIF: no image found")
}
