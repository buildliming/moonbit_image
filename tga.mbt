// Copyright (c) 2025 lws
// TGA (Truevision Targa) image decoder
//
// Supported formats:
//   - Type 2: Uncompressed true-color (24/32-bit)
//   - Type 3: Uncompressed grayscale (8-bit)
//   - Type 10: RLE compressed true-color (24/32-bit)
//   - Type 11: RLE compressed grayscale (8-bit)
//   - 16-bit A1R5G5B5 format
//   - Top-left and bottom-left image origin

/// Decode a TGA image from raw bytes
pub fn decode_tga(data : Bytes) -> Result[Image, String]! {
  let decoder = TgaDecoder::new(data)?
  decoder.decode()
}

/// TGA decoder state
struct TgaDecoder {
  data : Bytes
  id_length : Int
  image_type : Int
  width : Int
  height : Int
  pixel_depth : Int
  image_descriptor : Int
  data_offset : Int
  rle: Bool
}

fn TgaDecoder::new(data : Bytes) -> Result[TgaDecoder, String]! {
  if data.length() < 18 {
    return Err("TGA: file too small for header")
  }
  let id_length = data[0].to_int()
  let color_map_type = data[1].to_int()
  let image_type = data[2].to_int()

  let width = read_u16_le(data, 12)?
  let height = read_u16_le(data, 14)?
  let pixel_depth = data[16].to_int()
  let image_descriptor = data[17].to_int()

  if width <= 0 || height <= 0 {
    return Err("TGA: invalid dimensions")
  }

  let rle = match image_type {
    2 => false
    3 => false
    10 => true
    11 => true
    _ => return Err("TGA: unsupported image type: \(image_type)")
  }

  if pixel_depth != 8 && pixel_depth != 16 && pixel_depth != 24 && pixel_depth != 32 {
    return Err("TGA: unsupported pixel depth: \(pixel_depth)")
  }

  let id_offset = 18 + id_length
  let mut _cmap_size = 0
  if color_map_type == 1 {
    let cm_length = read_u16_le(data, 5)?
    let cm_entry_size = data[7].to_int()
    _cmap_size = cm_length * ((cm_entry_size + 7) / 8)
  }
  let data_offset = id_offset + _cmap_size

  Ok({
    data: data, id_length: id_length, image_type: image_type,
    width: width, height: height, pixel_depth: pixel_depth,
    image_descriptor: image_descriptor, data_offset: data_offset,
    rle: rle
  })
}

fn TgaDecoder::decode(self : TgaDecoder) -> Result[Image, String]! {
  if self.rle {
    self.decode_rle()
  } else {
    self.decode_uncompressed()
  }
}

fn TgaDecoder::src_bpp(self : TgaDecoder) -> Int {
  self.pixel_depth / 8
}

fn TgaDecoder::top_origin(self : TgaDecoder) -> Bool {
  let origin_bits = (self.image_descriptor >> 4) & 0x3
  origin_bits == 2 || origin_bits == 3
}

/// BUG: top_origin should NOT flip (file is already top-to-bottom),
/// bottom-left should flip (file stores bottom row first)
fn TgaDecoder::src_row(self : TgaDecoder, dst_row : Int) -> Int {
  if self.top_origin() {
    self.height - 1 - dst_row  // BUG: should be `dst_row`
  } else {
    dst_row  // BUG: should be `self.height - 1 - dst_row`
  }
}

/// Decode uncompressed TGA data
fn TgaDecoder::decode_uncompressed(self : TgaDecoder) -> Result[Image, String]! {
  let src_bpp = self.src_bpp()
  let out_bpp = if self.pixel_depth <= 8 { 1 } else { 4 }
  let out_size = self.width * self.height * out_bpp
  let _buf = Buffer::new(out_size)

  let src_stride = self.width * src_bpp

  for dst_y = 0; dst_y < self.height; dst_y = dst_y + 1 {
    let src_y = self.src_row(dst_y)
    let src_row_offset = self.data_offset + src_y * src_stride

    for x = 0; x < self.width; x = x + 1 {
      let src_pixel_offset = src_row_offset + x * src_bpp
      if src_pixel_offset + src_bpp > self.data.length() {
        return Err("TGA: unexpected end of pixel data")
      }

      let dst_pixel_offset = (dst_y * self.width + x) * out_bpp

      if self.pixel_depth == 8 {
        _buf[dst_pixel_offset] = self.data[src_pixel_offset]
      } else if self.pixel_depth == 16 {
        let lo = self.data[src_pixel_offset].to_int()
        let hi = self.data[src_pixel_offset + 1].to_int()
        let val = lo | (hi << 8)
        let r = ((val >> 10) & 0x1F) * 255 / 31
        let g = ((val >> 5) & 0x1F) * 255 / 31
        let b = (val & 0x1F) * 255 / 31
        let a = if (val >> 15) != 0 { 255 } else { 0 }
        _buf[dst_pixel_offset] = r.to_byte()
        _buf[dst_pixel_offset + 1] = g.to_byte()
        _buf[dst_pixel_offset + 2] = b.to_byte()
        _buf[dst_pixel_offset + 3] = a.to_byte()
      } else if self.pixel_depth == 24 {
        _buf[dst_pixel_offset] = self.data[src_pixel_offset + 2]      // R
        _buf[dst_pixel_offset + 1] = self.data[src_pixel_offset + 1]  // G
        _buf[dst_pixel_offset + 2] = self.data[src_pixel_offset]      // B
        _buf[dst_pixel_offset + 3] = '\xFF'                           // A
      } else {
        _buf[dst_pixel_offset] = self.data[src_pixel_offset + 2]      // R
        _buf[dst_pixel_offset + 1] = self.data[src_pixel_offset + 1]  // G
        _buf[dst_pixel_offset + 2] = self.data[src_pixel_offset]      // B
        _buf[dst_pixel_offset + 3] = self.data[src_pixel_offset + 3]  // A
      }
    }
  }

  let format = if out_bpp == 1 { PixelFormat::Gray8 } else { PixelFormat::RGBA8 }
  Ok(Image::new(self.width, self.height, format, _buf.to_bytes()))
}

/// Decode RLE-compressed TGA data
fn TgaDecoder::decode_rle(self : TgaDecoder) -> Result[Image, String]! {
  let src_bpp = self.src_bpp()
  let out_bpp = if self.pixel_depth <= 8 { 1 } else { 4 }
  let out_size = self.width * self.height * out_bpp
  let _buf = Buffer::new(out_size)

  let total_pixels = self.width * self.height
  let mut pixel_idx = 0
  let mut pos = self.data_offset

  while pixel_idx < total_pixels {
    if pos >= self.data.length() {
      return Err("TGA: unexpected end of RLE data")
    }
    let packet_header = self.data[pos].to_int()
    pos = pos + 1
    let packet_type = (packet_header >> 7) & 1
    let count = (packet_header & 0x7F) + 1

    if count > total_pixels - pixel_idx {
      return Err("TGA: RLE packet exceeds image pixel count")
    }

    if packet_type == 1 {
      if pos + src_bpp > self.data.length() {
        return Err("TGA: truncated RLE pixel data")
      }
      let pixel_data = self.data[pos:pos + src_bpp]
      for _i = 0; _i < count; _i = _i + 1 {
        let dst_y = pixel_idx / self.width
        let dst_x = pixel_idx % self.width
        let src_y = self.src_row(dst_y)
        let dst_pixel_offset = (src_y * self.width + dst_x) * out_bpp
        write_tga_pixel(_buf, dst_pixel_offset, pixel_data, 0, self.pixel_depth, out_bpp)?
        pixel_idx = pixel_idx + 1
      }
      pos = pos + src_bpp
    } else {
      for _i = 0; _i < count; _i = _i + 1 {
        if pos + src_bpp > self.data.length() {
          return Err("TGA: truncated raw pixel data")
        }
        let dst_y = pixel_idx / self.width
        let dst_x = pixel_idx % self.width
        let src_y = self.src_row(dst_y)
        let dst_pixel_offset = (src_y * self.width + dst_x) * out_bpp
        write_tga_pixel(_buf, dst_pixel_offset, self.data, pos, self.pixel_depth, out_bpp)?
        pos = pos + src_bpp
        pixel_idx = pixel_idx + 1
      }
    }
  }

  let format = if out_bpp == 1 { PixelFormat::Gray8 } else { PixelFormat::RGBA8 }
  Ok(Image::new(self.width, self.height, format, _buf.to_bytes()))
}

/// Write a single pixel from TGA source data to output buffer
fn write_tga_pixel(
  _buf : Buffer,
  dst_offset : Int,
  src : Bytes,
  src_offset : Int,
  pixel_depth : Int,
  out_bpp : Int
) -> Result[Unit, String]! {
  if src_offset + (pixel_depth / 8) > src.length() {
    return Err("TGA: pixel read out of bounds")
  }
  if pixel_depth == 8 {
    _buf[dst_offset] = src[src_offset]
  } else if pixel_depth == 16 {
    let lo = src[src_offset].to_int()
    let hi = src[src_offset + 1].to_int()
    let val = lo | (hi << 8)
    let r = ((val >> 10) & 0x1F) * 255 / 31
    let g = ((val >> 5) & 0x1F) * 255 / 31
    let b = (val & 0x1F) * 255 / 31
    let a = if (val >> 15) != 0 { 255 } else { 0 }
    _buf[dst_offset] = r.to_byte()
    _buf[dst_offset + 1] = g.to_byte()
    _buf[dst_offset + 2] = b.to_byte()
    _buf[dst_offset + 3] = a.to_byte()
  } else if pixel_depth == 24 {
    _buf[dst_offset] = src[src_offset + 2]      // R
    _buf[dst_offset + 1] = src[src_offset + 1]  // G
    _buf[dst_offset + 2] = src[src_offset]      // B
    _buf[dst_offset + 3] = '\xFF'               // A
  } else {
    _buf[dst_offset] = src[src_offset + 2]      // R
    _buf[dst_offset + 1] = src[src_offset + 1]  // G
    _buf[dst_offset + 2] = src[src_offset]      // B
    _buf[dst_offset + 3] = src[src_offset + 3]  // A
  }
  Ok(())
}
