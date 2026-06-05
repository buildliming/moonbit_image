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
  let img = @image.decode(data)
  
  println("Image: \{img.width} x \{img.height}")
  println("Format: \{pixel_format_name(img.format)}")
  
  // Access individual pixels
  let pixel = img.get_pixel(10, 20)
  println("Pixel: R=\{pixel.r} G=\{pixel.g} B=\{pixel.b} A=\{pixel.a}")
}
```

## API Reference

### Unified Decode

```moonbit
// Auto-detect format and decode
pub fn decode(data : Bytes) -> Image raise Failure

// Decode with known format
pub fn decode_by_format(data : Bytes, format : ImageFormat) -> Image raise Failure

// Detect format from magic bytes
pub fn detect_format(data : Bytes) -> Option[ImageFormat]

// Check if data matches any supported format
pub fn is_supported_format(data : Bytes) -> Bool

// Get human-readable pixel format name
pub fn pixel_format_name(format : PixelFormat) -> String
```

### Format-Specific Decoders

```moonbit
pub fn decode_bmp(data : Bytes) -> Image raise Failure
pub fn decode_qoi(data : Bytes) -> Image raise Failure
pub fn decode_tga(data : Bytes) -> Image raise Failure
pub fn decode_png(data : Bytes) -> Image raise Failure
```

### Image Type

```moonbit
pub struct Image {
  width : Int
  height : Int
  format : PixelFormat
  data : Bytes  // Raw pixel data, row-major
}

// Constructors & methods
pub fn Image::new(width : Int, height : Int, format : PixelFormat, data : Bytes) -> Image
pub fn Image::get_pixel(self : Image, x : Int, y : Int) -> Color
pub fn Image::to_rgba8(self : Image) -> Image
pub fn Image::bytes_per_pixel(self : Image) -> Int
```

### PixelFormat

```moonbit
pub enum PixelFormat {
  Gray8   // 8-bit grayscale
  GrayA8  // 16-bit grayscale + alpha
  RGB8    // 24-bit RGB
  RGBA8   // 32-bit RGBA
}
```

## Architecture

```
lws/image
├── lib.mbt                    # Main entry: format detection + dispatch
├── types.mbt                  # Core types: Image, Color, PixelFormat, BitReader
├── utils.mbt                  # Byte reading utilities, CRC32, Adler32
├── bmp.mbt                    # BMP decoder
├── qoi.mbt                    # QOI decoder
├── tga.mbt                    # TGA decoder
├── png.mbt                    # PNG decoder + DEFLATE decompressor
├── image_test.mbt             # Core tests: 24 tests covering small images + error paths
├── medium_image_test.mbt      # Medium-size tests: 64×64 images of all 4 formats
├── complex_image_test.mbt     # Complex pattern tests: 128×128 checkerboard, noise, etc.
└── test_images/               # Generated test images (64/128/256/512/2048 px)
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

- 8-bit depth: grayscale, RGB, RGBA, grayscale+alpha, indexed color (PLTE)
- Full DEFLATE decompression (RFC 1951)
  - Uncompressed blocks (BTYPE=0)
  - Fixed Huffman codes (BTYPE=1)
  - Dynamic Huffman codes (BTYPE=2)
- All five PNG filter types: None, Sub, Up, Average, Paeth
- zlib wrapper (RFC 1950) with header verification
- CRC32 chunk integrity checking
- Adam7 interlaced images

### Limitations (Future Work)

- 16-bit per channel depth (currently 8-bit only)
- 1/2/4-bit indexed PNG support (indexed color at 8-bit is supported)
- Ancillary chunk parsing (gAMA, cHRM, sRGB, etc.)
- Streaming/incremental decode
- Image encoders (write/save support)

## License

MIT

## Testing

The project includes 45 tests across 3 test files:

```bash
moon test   # Run all 45 tests
```

Tests cover:
- **Small images** (2×2 ~ 8×8): format-specific decoder correctness
- **Medium images** (64×64): full pixel checksum verification for all 4 formats
- **Complex patterns** (128×128): checkerboard, noise, radial gradient, Mandelbrot fractal — stresses DEFLATE compression, RLE, Huffman decoding under diverse data patterns
- **Error handling**: truncated data, invalid magic bytes, unsupported parameters, RLE overflow, CRC mismatches
- **Large images** (up to 2048×2048): verified via Python/PIL reference decoder

## Contributing

This library aims to build out the MoonBit image processing ecosystem. Planned future additions:
- Additional formats (JPEG, WebP, GIF)
- Image processing operations (resize, rotate, filters)
- CLI/Web demo application
