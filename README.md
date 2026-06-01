# image - Pure MoonBit Image Decoding Library

A comprehensive image decoding library written entirely in MoonBit, supporting multiple popular image formats with zero external dependencies.

## Supported Formats

| Format | Status | Description |
|--------|--------|-------------|
| **BMP** | ✅ Complete | 1/4/8/24/32-bit, top-down & bottom-up |
| **QOI** | ✅ Complete | RGB & RGBA, full spec compliance |
| **TGA** | ✅ Complete | Uncompressed & RLE, 8/16/24/32-bit |
| **PNG** | ✅ Complete | 8-bit grayscale/RGB/RGBA, DEFLATE decompression |

## Installation

```bash
moon add lws/image
```

## Quick Start

```moonbit
fn main {
  // Auto-detect format and decode
  let data = read_file("photo.png")
  let img = @image.decode(data)?
  
  println("Image: \(img.width) x \(img.height)")
  println("Format: \(img.format)")
  
  // Access individual pixels
  let pixel = img.get_pixel(10, 20)
  println("Pixel at (10,20): R=\(pixel.r) G=\(pixel.g) B=\(pixel.b) A=\(pixel.a)")
}
```

## API Reference

### Unified Decode

```moonbit
// Auto-detect format and decode
pub fn decode(data : Bytes) -> Result[Image, String]!

// Decode with known format
pub fn decode_by_format(data : Bytes, format : ImageFormat) -> Result[Image, String]!

// Detect format from magic bytes
pub fn detect_format(data : Bytes) -> Option[ImageFormat]
```

### Format-Specific Decoders

```moonbit
pub fn decode_bmp(data : Bytes) -> Result[Image, String]!
pub fn decode_qoi(data : Bytes) -> Result[Image, String]!
pub fn decode_tga(data : Bytes) -> Result[Image, String]!
pub fn decode_png(data : Bytes) -> Result[Image, String]!
```

### Image Type

```moonbit
pub struct Image {
  pub width : Int
  pub height : Int
  pub format : PixelFormat
  pub data : Bytes  // Raw pixel data, row-major
}

// Methods
pub fn Image::get_pixel(self : Image, x : Int, y : Int) -> Color
pub fn Image::to_rgba8(self : Image) -> Image
pub fn Image::bytes_per_pixel(self : Image) -> Int
pub fn Image::stride(self : Image) -> Int
```

### PixelFormat

```moonbit
pub enum PixelFormat {
  Gray8   // 8-bit grayscale
  GrayA8  // 16-bit grayscale + alpha
  RGB8    // 24-bit RGB
  RGBA8   // 32-bit RGBA
  BGR8    // 24-bit BGR
  BGRA8   // 32-bit BGRA
}
```

## Architecture

```
lws/image
├── lib.mbt          # Main entry: format detection + dispatch
├── types.mbt        # Core types: Image, Color, PixelFormat, BitReader
├── utils.mbt        # Byte reading utilities, CRC32, Adler32
├── bmp.mbt          # BMP decoder
├── qoi.mbt          # QOI decoder
├── tga.mbt          # TGA decoder
└── png.mbt          # PNG decoder + DEFLATE decompressor
```

## Supported BMP Features

- 32-bit BGRA (uncompressed)
- 24-bit BGR (uncompressed)
- 8-bit indexed (with palette)
- 4-bit indexed (with palette)
- 1-bit monochrome
- Top-down and bottom-up scan order
- Automatic 4-byte row alignment handling

## Supported QOI Features

- RGB (3-channel) and RGBA (4-channel)
- All QOI chunk types: INDEX, DIFF, LUMA, RUN, RGB, RGBA
- Full color hash cache implementation
- sRGB and linear colorspace detection

## Supported TGA Features

- Type 2: Uncompressed true-color (24/32-bit)
- Type 3: Uncompressed grayscale (8-bit)
- Type 10: RLE compressed true-color (24/32-bit)
- Type 11: RLE compressed grayscale (8-bit)
- Top-left and bottom-left image origin
- 16-bit A1R5G5B5 format support

## Supported PNG Features

- 8-bit depth: grayscale, RGB, RGBA, grayscale+alpha
- Full DEFLATE decompression (RFC 1951)
  - Uncompressed blocks (BTYPE=0)
  - Fixed Huffman codes (BTYPE=1)
  - Dynamic Huffman codes (BTYPE=2)
- All five PNG filter types: None, Sub, Up, Average, Paeth
- zlib wrapper (RFC 1950) with header verification
- CRC32 chunk integrity checking
- Non-interlaced images

### Limitations (Future Work)

- 16-bit per channel support
- Indexed color (PLTE chunk) support
- Adam7 interlacing
- Ancillary chunk parsing (gAMA, cHRM, sRGB, etc.)
- Streaming/incremental decode

## License

MIT

## Contributing

This library aims to build out the MoonBit image processing ecosystem. Planned future additions:
- Image encoders (write/save support)
- Additional formats (JPEG, WebP, GIF, TIFF)
- Image processing operations (resize, rotate, filters)
