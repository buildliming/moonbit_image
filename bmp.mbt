// Copyright (c) 2025 lws
// BMP (Bitmap) image decoder
//
// Supported BMP formats:
//   - 32-bit BGRA (uncompressed)
//   - 24-bit BGR (uncompressed)
//   - 8-bit indexed (with palette)
//   - 4-bit indexed (with palette)
//   - 1-bit monochrome (with palette / B&W)
//   - Top-down and bottom-up scan order

// BMP file header (14 bytes)
// Offset  Size  Description
// 0       2     Signature "BM" (0x424D)
// 2       4     File size in bytes
// 6       2     Reserved
// 8       2     Reserved
// 10      4     Offset to pixel data

// DIB header (BITMAPINFOHEADER, 40 bytes)
// 14      4     DIB header size (40 for BITMAPINFOHEADER)
// 18      4     Width in pixels (signed, negative = top-down)
// 22      4     Height in pixels (signed, negative = top-down)
// 26      2     Color planes (must be 1)
// 28      2     Bits per pixel (1, 4, 8, 16, 24, 32)
// 30      4     Compression method (0=BI_RGB, 3=BI_BITFIELDS)

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
}

fn BmpDecoder::new(data : Bytes) -> Result[BmpDecoder, String]! {
  if data.length() < 2 {
    return Err("BMP: file too small for signature")
  }
  if data[0] != 'B' || data[1] != 'M' {
    return Err("BMP: invalid signature, expected 'BM'")
  }
  let data_offset = read_u32_le(data, 10)?
  if data.length() < 18 {
    return Err("BMP: file too small for DIB header")
  }
  let dib_size = read_u32_le(data, 14)?
  if dib_size < 40 {
    return Err("BMP: unsupported DIB header (BITMAPINFOHEADER required)")
  }
  let width_raw = read_u32_le(data, 18)?
  let height_raw = read_u32_le(data, 22)?
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
    bpp: bpp, compression: compression, data_offset: data_offset
  })
}

fn BmpDecoder::decode(self : BmpDecoder) -> Result[Image, String]! {
  match self.bpp {
    32 => self.decode_rgba()
    24 => self.decode_24bit()
    8 => self.decode_8bit()
    4 => self.decode_4bit()
    1 => self.decode_1bit()
    _ => Err("BMP: unsupported bit depth: \(self.bpp)")
  }
}

/// Row stride in bytes (padded to 4-byte boundary)
fn bmp_row_stride(width : Int, bpp : Int) -> Int {
  let row_bits = width * bpp
  let row_bytes = (row_bits + 7) / 8
  ((row_bytes + 3) / 4) * 4
}

/// Read palette from BMP data (after DIB header)
fn read_palette(data : Bytes, num_colors : Int) -> Array[Color] {
  let palette_offset = 14 + 40
  let palette = Array::make(num_colors, Color::default())
  for i = 0; i < num_colors && i * 4 + palette_offset + 3 < data.length(); i = i + 1 {
    let offset = palette_offset + i * 4
    let b = data[offset].to_int()
    let g = data[offset + 1].to_int()
    let r = data[offset + 2].to_int()
    palette[i] = Color::new(r, g, b, 255)
  }
  palette
}

/// Decode 32-bit BGRA
fn BmpDecoder::decode_rgba(self : BmpDecoder) -> Result[Image, String]! {
  let stride = bmp_row_stride(self.width, 32)
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col * 4
      if src + 3 >= self.data.length() {
        return Err("BMP: unexpected end of pixel data")
      }
      let dst = (row * self.width + col) * 4
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
  let out_size = self.width * self.height * 3
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col * 3
      if src + 2 >= self.data.length() {
        return Err("BMP: unexpected end of pixel data")
      }
      let dst = (row * self.width + col) * 3
      _buf[dst] = self.data[src + 2]      // R
      _buf[dst + 1] = self.data[src + 1]  // G
      _buf[dst + 2] = self.data[src]      // B
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGB8, _buf.to_bytes()))
}

/// Decode 8-bit indexed
fn BmpDecoder::decode_8bit(self : BmpDecoder) -> Result[Image, String]! {
  let palette = read_palette(self.data, 256)
  let stride = bmp_row_stride(self.width, 8)
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col
      if src >= self.data.length() {
        return Err("BMP: unexpected end of pixel data")
      }
      let idx = self.data[src].to_int()
      let c = if idx < 256 { palette[idx] } else { Color::default() }
      let dst = (row * self.width + col) * 4
      _buf[dst] = c.r.to_byte()
      _buf[dst + 1] = c.g.to_byte()
      _buf[dst + 2] = c.b.to_byte()
      _buf[dst + 3] = c.a.to_byte()
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

/// Decode 4-bit indexed
fn BmpDecoder::decode_4bit(self : BmpDecoder) -> Result[Image, String]! {
  let palette = read_palette(self.data, 16)
  let stride = bmp_row_stride(self.width, 4)
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col / 2
      if src >= self.data.length() {
        return Err("BMP: unexpected end of pixel data")
      }
      let byte_val = self.data[src].to_int()
      let idx = if col % 2 == 0 { (byte_val >> 4) & 0xF } else { byte_val & 0xF }
      let c = if idx < 16 { palette[idx] } else { Color::default() }
      let dst = (row * self.width + col) * 4
      _buf[dst] = c.r.to_byte()
      _buf[dst + 1] = c.g.to_byte()
      _buf[dst + 2] = c.b.to_byte()
      _buf[dst + 3] = c.a.to_byte()
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}

/// Decode 1-bit monochrome
fn BmpDecoder::decode_1bit(self : BmpDecoder) -> Result[Image, String]! {
  let palette = read_palette(self.data, 2)
  let stride = bmp_row_stride(self.width, 1)
  let out_size = self.width * self.height * 4
  let _buf = Buffer::new(out_size)

  for row = 0; row < self.height; row = row + 1 {
    let src_row = if self.top_down { row } else { self.height - 1 - row }
    let row_offset = self.data_offset + src_row * stride
    for col = 0; col < self.width; col = col + 1 {
      let src = row_offset + col / 8
      if src >= self.data.length() {
        return Err("BMP: unexpected end of pixel data")
      }
      let byte_val = self.data[src].to_int()
      let bit = (byte_val >> (7 - col % 8)) & 1
      let c = if bit < 2 { palette[bit] } else { Color::default() }
      let dst = (row * self.width + col) * 4
      _buf[dst] = c.r.to_byte()
      _buf[dst + 1] = c.g.to_byte()
      _buf[dst + 2] = c.b.to_byte()
      _buf[dst + 3] = c.a.to_byte()
    }
  }
  Ok(Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes()))
}
