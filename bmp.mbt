// Copyright (c) 2025 lws
// BMP (Bitmap) image decoder
//
// Supported BMP formats:
//   - 32-bit BGRA (uncompressed + BITFIELDS)
//   - 24-bit BGR (uncompressed)
//   - 8-bit indexed with RLE8 compression
//   - 4-bit indexed with RLE4 compression
//   - 1-bit monochrome (with palette / B&W)
//   - Top-down and bottom-up scan order

// Compression types
let BI_RGB       : Int = 0
let BI_RLE8      : Int = 1
let BI_RLE4      : Int = 2
let BI_BITFIELDS : Int = 3

//-----------------------------------------------------------------------------
// BMP Decoder
//-----------------------------------------------------------------------------

/// Decode a BMP image from raw bytes
pub fn decode_bmp(data : Bytes) -> Result[Image, String]! {
  let decoder = BmpDecoder::new(data)?
  decoder.decode()
}

/// BMP decoder state machine
struct BmpDecoder {
  data : Bytes
  width : Int
  height : Int
  top_down : Bool
  bpp : Int
  compression : Int
  data_offset : Int
  dib_size : Int
  palette : Array[Color]
}

fn BmpDecoder::new(data : Bytes) -> Result[BmpDecoder, String]! {
  // Verify BMP signature
  if data.length() < 2 {
    return Err("BMP: file too small for signature")
  }
  if data[0] != 'B' || data[1] != 'M' {
    return Err("BMP: invalid signature, expected 'BM'")
  }
  // Read data offset from file header
  let data_offset = read_u32_le(data, 10)?
  // Read DIB header
  if data.length() < 18 {
    return Err("BMP: file too small for DIB header")
  }
  let dib_size = read_u32_le(data, 14)?
  if dib_size < 40 {
    return Err("BMP: unsupported DIB header (BITMAPINFOHEADER required)")
  }
  let width_raw = read_u32_le(data, 18)?
  let height_raw = read_u32_le(data, 22)?
  // Height can be signed: positive = bottom-up, negative = top-down
  let top_down = height_raw < 0
  let height = if top_down { -height_raw } else { height_raw }
  let width = width_raw
  if width <= 0 || height <= 0 {
    return Err("BMP: invalid dimensions")
  }
  let bpp = read_u16_le(data, 28)?
  let compression = read_u32_le(data, 30)?
  Ok({
    data: data, width: width, height: height, top_down: top_down,
    bpp: bpp, compression: compression, data_offset: data_offset,
    dib_size: dib_size,
    palette: Array::make(0, Color::default())
  })
}

fn BmpDecoder::decode(self : BmpDecoder) -> Result[Image, String]! {
  match self.bpp {
    32 => self.decode_rgba()
    24 => self.decode_24bit()
    8 => if self.compression == BI_RLE8 { self.decode_rle8() } else { self.decode_8bit() }
    4 => if self.compression == BI_RLE4 { self.decode_rle4() } else { self.decode_4bit() }
    1 => self.decode_1bit()
    _ => Err("BMP: unsupported bit depth: \(self.bpp)")
  }
}

/// Read palette from BMP data (after DIB header)
fn BmpDecoder::read_palette(self : BmpDecoder, num_colors : Int) -> Array[Color] {
  let palette_offset = 14 + self.dib_size  // file header + DIB header
  let palette = Array::make(num_colors, Color::default())
  for i = 0; i < num_colors && i * 4 + palette_offset + 3 < self.data.length(); i = i + 1 {
    let offset = palette_offset + i * 4
    let b = self.data[offset].to_int()
    let g = self.data[offset + 1].to_int()
    let r = self.data[offset + 2].to_int()
    palette[i] = Color::new(r, g, b, 255)
  }
  palette
}

/// Pre-compute palette as RGBA byte quads for fast indexed decoding
fn palette_to_rgba_bytes(palette : Array[Color]) -> Array[Array[Byte]] {
  let result = Array::make(palette.length(), ['\x00', '\x00', '\x00', '\xFF'])
  for i = 0; i < palette.length(); i = i + 1 {
    let c = palette[i]
    result[i] = [c.r.to_byte(), c.g.to_byte(), c.b.to_byte(), c.a.to_byte()]
  }
  result
}

/// Row stride in bytes (padded to 4-byte boundary)
fn bmp_row_stride(width : Int, bpp : Int) -> Int {
  let row_bits = width * bpp
  let row_bytes = (row_bits + 7) / 8
  ((row_bytes + 3) / 4) * 4
}

/// Write a palette color to the output buffer at a pixel position
fn write_palette_pixel(
  _buf : Buffer, dst : Int, idx : Int, num_colors : Int,
  palette_rgba : Array[Array[Byte]]
) -> Unit {
  if idx < num_colors {
    let c = palette_rgba[idx]
    _buf[dst] = c[0]
    _buf[dst + 1] = c[1]
    _buf[dst + 2] = c[2]
    _buf[dst + 3] = c[3]
  } else {
    _buf[dst] = '\x00'
    _buf[dst + 1] = '\x00'
    _buf[dst + 2] = '\x00'
    _buf[dst + 3] = '\xFF'
  }
}

/// Decode 32-bit BGRA
fn BmpDecoder::decode_rgba(self : BmpDecoder) -> Result[Image, String]! {
  let stride = bmp_row_stride(self.width, 32)
  // Upfront bounds validation: total pixel data region must fit
  if self.data.length() < self.data_offset + self.height * stride {
    return Err("BMP: unexpected end of pixel data")
  }
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col * 4
      let dst = (row * self.width + col) * 4
      // BMP stores BGRA in little-endian: byte order is B, G, R, A
      _buf[dst] = self.data[src + 2]      // R
      _buf[dst + 1] = self.data[src + 1]  // G
      _buf[dst + 2] = self.data[src]      // B
      _buf[dst + 3] = self.data[src + 3]  // A
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

/// Decode 24-bit BGR
fn BmpDecoder::decode_24bit(self : BmpDecoder) -> Result[Image, String]! {
  let stride = bmp_row_stride(self.width, 24)
  // Upfront bounds validation: total pixel data region must fit
  if self.data.length() < self.data_offset + self.height * stride {
    return Err("BMP: unexpected end of pixel data")
  }
  let out_size = self.width * self.height * 3
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col * 3
      let dst = (row * self.width + col) * 3
      // BMP stores BGR
      _buf[dst] = self.data[src + 2]      // R
      _buf[dst + 1] = self.data[src + 1]  // G
      _buf[dst + 2] = self.data[src]      // B
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGB8, _buf.to_bytes()))
}

/// Decode 8-bit indexed (uncompressed) — uses pre-computed palette
fn BmpDecoder::decode_8bit(self : BmpDecoder) -> Result[Image, String]! {
  let palette = self.read_palette(256)
  let palette_rgba = palette_to_rgba_bytes(palette)
  let stride = bmp_row_stride(self.width, 8)
  // Upfront bounds validation
  if self.data.length() < self.data_offset + self.height * stride {
    return Err("BMP: unexpected end of pixel data")
  }
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col
      let idx = self.data[src].to_int()
      let dst = (row * self.width + col) * 4
      write_palette_pixel(_buf, dst, idx, 256, palette_rgba)
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

/// Decode 4-bit indexed (uncompressed)
fn BmpDecoder::decode_4bit(self : BmpDecoder) -> Result[Image, String]! {
  let palette = self.read_palette(16)
  let palette_rgba = palette_to_rgba_bytes(palette)
  let stride = bmp_row_stride(self.width, 4)
  // Upfront bounds validation
  if self.data.length() < self.data_offset + self.height * stride {
    return Err("BMP: unexpected end of pixel data")
  }
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col / 2
      let byte_val = self.data[src].to_int()
      // High nibble first (leftmost pixel)
      let idx = if col % 2 == 0 { (byte_val >> 4) & 0xF } else { byte_val & 0xF }
      let dst = (row * self.width + col) * 4
      write_palette_pixel(_buf, dst, idx, 16, palette_rgba)
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

/// Decode 1-bit monochrome
fn BmpDecoder::decode_1bit(self : BmpDecoder) -> Result[Image, String]! {
  let palette = self.read_palette(2)
  let palette_rgba = palette_to_rgba_bytes(palette)
  let stride = bmp_row_stride(self.width, 1)
  // Upfront bounds validation
  if self.data.length() < self.data_offset + self.height * stride {
    return Err("BMP: unexpected end of pixel data")
  }
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col / 8
      let byte_val = self.data[src].to_int()
      // MSB first (leftmost pixel is bit 7)
      let bit = (byte_val >> (7 - col % 8)) & 1
      let dst = (row * self.width + col) * 4
      write_palette_pixel(_buf, dst, bit, 2, palette_rgba)
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

//-----------------------------------------------------------------------------
// BMP RLE8 Decoder
//-----------------------------------------------------------------------------

/// Decode RLE8 compressed 8-bit BMP
/// Uses valid_row flag updated on row transitions to avoid per-pixel bounds checks
fn BmpDecoder::decode_rle8(self : BmpDecoder) -> Result[Image, String]! {
  let palette = self.read_palette(256)
  let palette_rgba = palette_to_rgba_bytes(palette)
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  let mut pos = self.data_offset
  let mut row = if self.top_down { 0 } else { self.height - 1 }
  let mut col = 0
  let row_step = if self.top_down { 1 } else { -1 }
  let mut valid_row = true  // Initial row is always valid (height > 0 already validated)

  loop {
    if pos + 1 >= self.data.length() {
      return Err("BMP RLE8: unexpected end of data")
    }
    let count = self.data[pos].to_int()
    let value = self.data[pos + 1].to_int()
    pos = pos + 2

    if count == 0 {
      if value == 0 {
        // End of line
        row = row + row_step
        valid_row = row >= 0 && row < self.height
        col = 0
      } else if value == 1 {
        // End of bitmap
        break
      } else if value == 2 {
        // Delta: move to new position
        if pos + 1 >= self.data.length() {
          return Err("BMP RLE8: truncated delta")
        }
        let dx = self.data[pos].to_int()
        let dy = self.data[pos + 1].to_int()
        pos = pos + 2
        col = col + dx
        row = row + row_step * dy
        valid_row = row >= 0 && row < self.height
      } else {
        // Absolute run: next `value` bytes are literal indices
        let run_len = value
        if pos + run_len > self.data.length() {
          return Err("BMP RLE8: truncated absolute run")
        }
        for i = 0; i < run_len; i = i + 1 {
          if valid_row {
            let idx = self.data[pos].to_int()
            let dst = (row * self.width + col) * 4
            write_palette_pixel(_buf, dst, idx, 256, palette_rgba)
          }
          col = col + 1
          pos = pos + 1
        }
        // Word-align: skip padding byte if run_len is odd
        if run_len % 2 == 1 && pos < self.data.length() {
          pos = pos + 1
        }
      }
    } else {
      // Encoded run: repeat `value` for `count` pixels
      for _i = 0; _i < count; _i = _i + 1 {
        if valid_row {
          let dst = (row * self.width + col) * 4
          write_palette_pixel(_buf, dst, value, 256, palette_rgba)
        }
        col = col + 1
      }
    }
  }

  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

//-----------------------------------------------------------------------------
// BMP RLE4 Decoder
//-----------------------------------------------------------------------------

/// Decode RLE4 compressed 4-bit BMP
/// Uses valid_row flag updated on row transitions to avoid per-pixel bounds checks
fn BmpDecoder::decode_rle4(self : BmpDecoder) -> Result[Image, String]! {
  let palette = self.read_palette(16)
  let palette_rgba = palette_to_rgba_bytes(palette)
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  let mut pos = self.data_offset
  let mut row = if self.top_down { 0 } else { self.height - 1 }
  let mut col = 0
  let row_step = if self.top_down { 1 } else { -1 }
  let mut valid_row = true  // Initial row is always valid (height > 0 already validated)

  loop {
    if pos + 1 >= self.data.length() {
      return Err("BMP RLE4: unexpected end of data")
    }
    let count = self.data[pos].to_int()
    let value = self.data[pos + 1].to_int()
    pos = pos + 2

    if count == 0 {
      if value == 0 {
        // End of line
        row = row + row_step
        valid_row = row >= 0 && row < self.height
        col = 0
      } else if value == 1 {
        // End of bitmap
        break
      } else if value == 2 {
        // Delta
        if pos + 1 >= self.data.length() {
          return Err("BMP RLE4: truncated delta")
        }
        let dx = self.data[pos].to_int()
        let dy = self.data[pos + 1].to_int()
        pos = pos + 2
        col = col + dx
        row = row + row_step * dy
        valid_row = row >= 0 && row < self.height
      } else {
        // Absolute run
        let num_pixels = value
        let num_bytes = (num_pixels + 1) / 2
        if pos + num_bytes > self.data.length() {
          return Err("BMP RLE4: truncated absolute run")
        }
        let mut pixels_read = 0
        for i = 0; i < num_bytes; i = i + 1 {
          let byte_val = self.data[pos].to_int()
          pos = pos + 1
          // High nibble first
          let idx_hi = (byte_val >> 4) & 0x0F
          if pixels_read < num_pixels && valid_row {
            let dst = (row * self.width + col) * 4
            write_palette_pixel(_buf, dst, idx_hi, 16, palette_rgba)
          }
          col = col + 1
          pixels_read = pixels_read + 1
          // Low nibble second
          let idx_lo = byte_val & 0x0F
          if pixels_read < num_pixels && valid_row {
            let dst = (row * self.width + col) * 4
            write_palette_pixel(_buf, dst, idx_lo, 16, palette_rgba)
          }
          col = col + 1
          pixels_read = pixels_read + 1
        }
        // Word-align
        if num_bytes % 2 == 1 && pos < self.data.length() {
          pos = pos + 1
        }
      }
    } else {
      // Encoded run: alternate between two nibbles
      let hi_nib = (value >> 4) & 0x0F
      let lo_nib = value & 0x0F
      for i = 0; i < count; i = i + 1 {
        let idx = if i % 2 == 0 { hi_nib } else { lo_nib }
        if valid_row {
          let dst = (row * self.width + col) * 4
          write_palette_pixel(_buf, dst, idx, 16, palette_rgba)
        }
        col = col + 1
      }
    }
  }

  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}
