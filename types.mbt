// Copyright (c) 2025 lws
// Image decoding library for MoonBit - Core types

//-----------------------------------------------------------------------------
// PixelFormat - Supported pixel layouts
//-----------------------------------------------------------------------------

/// All pixel formats supported by this library
pub enum PixelFormat {
  /// 8-bit grayscale (1 byte per pixel)
  Gray8
  /// 16-bit grayscale with alpha (2 bytes per pixel)
  GrayA8
  /// 24-bit RGB (3 bytes per pixel, R, G, B)
  RGB8
  /// 32-bit RGBA (4 bytes per pixel, R, G, B, A)
  RGBA8
  /// 24-bit BGR (3 bytes per pixel, B, G, R)
  BGR8
  /// 32-bit BGRA (4 bytes per pixel, B, G, R, A)
  BGRA8
}

//-----------------------------------------------------------------------------
// ImageFormat - Supported file formats
//-----------------------------------------------------------------------------

/// Image file formats that can be detected and decoded
pub enum ImageFormat {
  BMP
  QOI
  TGA
  PNG
}

//-----------------------------------------------------------------------------
// Color - A single pixel color value
//-----------------------------------------------------------------------------

/// A color represented as 8-bit RGBA components
pub struct Color {
  pub r : Int
  pub g : Int
  pub b : Int
  pub a : Int
}

/// Constructors and utilities for Color
pub fn Color::default() -> Color {
  { r: 0, g: 0, b: 0, a: 255 }
}

pub fn Color::new(r : Int, g : Int, b : Int, a : Int) -> Color {
  { r: r, g: g, b: b, a: a }
}

pub fn Color::from_rgb(r : Int, g : Int, b : Int) -> Color {
  { r: r, g: g, b: b, a: 255 }
}

pub fn Color::from_gray(v : Int) -> Color {
  { r: v, g: v, b: v, a: 255 }
}

pub fn Color::with_alpha(self : Color, a : Int) -> Color {
  { r: self.r, g: self.g, b: self.b, a: a }
}

pub fn Color::to_gray(self : Color) -> Int {
  // ITU-R BT.601 luma
  (self.r * 299 + self.g * 587 + self.b * 114) / 1000
}

//-----------------------------------------------------------------------------
// Image - The main image data structure
//-----------------------------------------------------------------------------

/// A decoded image with pixel data
pub struct Image {
  /// Image width in pixels
  pub width : Int
  /// Image height in pixels
  pub height : Int
  /// Pixel format describing the data layout
  pub format : PixelFormat
  /// Raw pixel data, row-major order (top to bottom)
  pub data : Bytes
}

pub fn Image::new(width : Int, height : Int, format : PixelFormat, data : Bytes) -> Image {
  { width: width, height: height, format: format, data: data }
}

/// Number of bytes per pixel for this format
pub fn Image::bytes_per_pixel(self : Image) -> Int {
  match self.format {
    PixelFormat::Gray8 => 1
    PixelFormat::GrayA8 => 2
    PixelFormat::RGB8 => 3
    PixelFormat::RGBA8 => 4
    PixelFormat::BGR8 => 3
    PixelFormat::BGRA8 => 4
  }
}

/// Number of bytes per row (stride) for this image
pub fn Image::stride(self : Image) -> Int {
  self.width * self.bytes_per_pixel()
}

/// Total size of pixel data in bytes
pub fn Image::data_size(self : Image) -> Int {
  self.stride() * self.height
}

/// Get the color at a specific pixel coordinate
pub fn Image::get_pixel(self : Image, x : Int, y : Int) -> Color {
  let offset = (y * self.stride()) + (x * self.bytes_per_pixel())
  match self.format {
    PixelFormat::Gray8 => {
      let v = self.data[offset].to_int()
      Color::from_gray(v)
    }
    PixelFormat::GrayA8 => {
      let v = self.data[offset].to_int()
      let a = self.data[offset + 1].to_int()
      Color::from_gray(v).with_alpha(a)
    }
    PixelFormat::RGB8 => {
      let r = self.data[offset].to_int()
      let g = self.data[offset + 1].to_int()
      let b = self.data[offset + 2].to_int()
      Color::new(r, g, b, 255)
    }
    PixelFormat::RGBA8 => {
      let r = self.data[offset].to_int()
      let g = self.data[offset + 1].to_int()
      let b = self.data[offset + 2].to_int()
      let a = self.data[offset + 3].to_int()
      Color::new(r, g, b, a)
    }
    PixelFormat::BGR8 => {
      let b = self.data[offset].to_int()
      let g = self.data[offset + 1].to_int()
      let r = self.data[offset + 2].to_int()
      Color::new(r, g, b, 255)
    }
    PixelFormat::BGRA8 => {
      let b = self.data[offset].to_int()
      let g = self.data[offset + 1].to_int()
      let r = self.data[offset + 2].to_int()
      let a = self.data[offset + 3].to_int()
      Color::new(r, g, b, a)
    }
  }
}

/// Convert this image to RGBA8 format (always 4 bytes per pixel)
/// Uses per-format bulk loops for performance (avoids per-pixel match dispatch)
pub fn Image::to_rgba8(self : Image) -> Image {
  if self.format == PixelFormat::RGBA8 {
    return self
  }
  let pixel_count = self.width * self.height
  let out_size = pixel_count * 4
  let _buf = Buffer::new(out_size)

  match self.format {
    PixelFormat::Gray8 => {
      for i = 0; i < pixel_count; i = i + 1 {
        let v = self.data[i].to_int()
        let dst = i * 4
        _buf[dst] = v.to_byte()
        _buf[dst + 1] = v.to_byte()
        _buf[dst + 2] = v.to_byte()
        _buf[dst + 3] = '\xFF'
      }
    }
    PixelFormat::GrayA8 => {
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 2
        let v = self.data[src].to_int()
        let a = self.data[src + 1]
        let dst = i * 4
        _buf[dst] = v.to_byte()
        _buf[dst + 1] = v.to_byte()
        _buf[dst + 2] = v.to_byte()
        _buf[dst + 3] = a
      }
    }
    PixelFormat::RGB8 => {
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 3
        let dst = i * 4
        _buf[dst] = self.data[src]
        _buf[dst + 1] = self.data[src + 1]
        _buf[dst + 2] = self.data[src + 2]
        _buf[dst + 3] = '\xFF'
      }
    }
    PixelFormat::BGR8 => {
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 3
        let dst = i * 4
        _buf[dst] = self.data[src + 2]      // R
        _buf[dst + 1] = self.data[src + 1]  // G
        _buf[dst + 2] = self.data[src]      // B
        _buf[dst + 3] = '\xFF'
      }
    }
    PixelFormat::BGRA8 => {
      for i = 0; i < pixel_count; i = i + 1 {
        let src = i * 4
        let dst = i * 4
        _buf[dst] = self.data[src + 2]      // R
        _buf[dst + 1] = self.data[src + 1]  // G
        _buf[dst + 2] = self.data[src]      // B
        _buf[dst + 3] = self.data[src + 3]  // A
      }
    }
    _ => {
      // Fallback: per-pixel conversion (should not reach here since RGBA8 is early-returned)
      for y = 0; y < self.height; y = y + 1 {
        for x = 0; x < self.width; x = x + 1 {
          let c = self.get_pixel(x, y)
          let offset = (y * self.width + x) * 4
          _buf[offset] = c.r.to_byte()
          _buf[offset + 1] = c.g.to_byte()
          _buf[offset + 2] = c.b.to_byte()
          _buf[offset + 3] = c.a.to_byte()
        }
      }
    }
  }
  Image::new(self.width, self.height, PixelFormat::RGBA8, _buf.to_bytes())
}

//-----------------------------------------------------------------------------
// BitReader - Bit-level reading from Bytes
//-----------------------------------------------------------------------------

/// Bit reader for DEFLATE and other bit-stream formats
/// Reads bits MSB-first (most significant bit first)
pub(all) struct BitReader {
  data : Bytes
  byte_pos : Int
  bit_pos : Int  // 0 = MSB, 7 = LSB
}

pub(all) fn BitReader::new(data : Bytes) -> BitReader {
  { data: data, byte_pos: 0, bit_pos: 0 }
}

/// Read a single bit (0 or 1)
pub(all) fn BitReader::read_bit(self : BitReader) -> Result[(BitReader, Int), String]! {
  if self.byte_pos >= self.data.length() {
    return Err("BitReader: unexpected end of data while reading bit")
  }
  let byte = self.data[self.byte_pos].to_int()
  let bit = (byte >> (7 - self.bit_pos)) & 1
  let new_bit_pos = self.bit_pos + 1
  let new_reader = if new_bit_pos > 7 {
    { data: self.data, byte_pos: self.byte_pos + 1, bit_pos: 0 }
  } else {
    { data: self.data, byte_pos: self.byte_pos, bit_pos: new_bit_pos }
  }
  Ok((new_reader, bit))
}

/// Read n bits as an integer, up to 16 bits
/// Uses batch byte reading instead of per-bit loops for performance
pub(all) fn BitReader::read_bits(self : BitReader, n : Int) -> Result[(BitReader, Int), String]! {
  if n == 0 {
    return Ok((self, 0))
  }
  if n > 16 {
    return Err("BitReader: cannot read more than 16 bits at once")
  }

  let mut reader = self
  let mut result = 0
  let mut needed = n

  // Read remaining bits from current partial byte first (these are the MSBs of our result)
  if reader.bit_pos != 0 {
    let bits_left = 8 - reader.bit_pos
    let take = if needed < bits_left { needed } else { bits_left }
    if reader.byte_pos >= reader.data.length() {
      return Err("BitReader: unexpected end of data while reading bits")
    }
    let byte = reader.data[reader.byte_pos].to_int()
    // Mask the remaining bits and shift to get the top `take` bits
    let mask = (1 << bits_left) - 1
    let val = (byte & mask) >> (bits_left - take)
    result = val
    needed = needed - take
    if take == bits_left {
      reader = { data: reader.data, byte_pos: reader.byte_pos + 1, bit_pos: 0 }
    } else {
      reader = { data: reader.data, byte_pos: reader.byte_pos, bit_pos: reader.bit_pos + take }
    }
    if needed == 0 {
      return Ok((reader, result))
    }
  }

  // Read full bytes (8 bits each)
  while needed >= 8 {
    if reader.byte_pos >= reader.data.length() {
      return Err("BitReader: unexpected end of data while reading bits")
    }
    result = (result << 8) | reader.data[reader.byte_pos].to_int()
    needed = needed - 8
    reader = { data: reader.data, byte_pos: reader.byte_pos + 1, bit_pos: 0 }
  }

  // Read remaining bits from next byte
  if needed > 0 {
    if reader.byte_pos >= reader.data.length() {
      return Err("BitReader: unexpected end of data while reading bits")
    }
    let byte = reader.data[reader.byte_pos].to_int()
    // Take the top `needed` bits (MSB-first within the byte)
    let val = byte >> (8 - needed)
    result = (result << needed) | val
    reader = { data: reader.data, byte_pos: reader.byte_pos, bit_pos: needed }
  }

  Ok((reader, result))
}

/// Align to the next byte boundary
pub(all) fn BitReader::align_to_byte(self : BitReader) -> BitReader {
  if self.bit_pos == 0 {
    self
  } else {
    { data: self.data, byte_pos: self.byte_pos + 1, bit_pos: 0 }
  }
}

/// Bytes remaining from current position
pub(all) fn BitReader::remaining_bytes(self : BitReader) -> Int {
  self.data.length() - self.byte_pos
}

/// Get a slice of remaining bytes
pub(all) fn BitReader::remaining_data(self : BitReader) -> Bytes {
  self.data[self.byte_pos:]
}

/// Read raw bytes from current byte position (must be byte-aligned)
pub(all) fn BitReader::read_bytes(self : BitReader, n : Int) -> Result[(BitReader, Bytes), String]! {
  if self.bit_pos != 0 {
    return Err("BitReader: cannot read bytes when not byte-aligned")
  }
  if self.byte_pos + n > self.data.length() {
    return Err("BitReader: unexpected end of data")
  }
  let slice = self.data[self.byte_pos:self.byte_pos + n]
  let new_reader = { data: self.data, byte_pos: self.byte_pos + n, bit_pos: 0 }
  Ok((new_reader, slice))
}
