# image - Pure MoonBit Image Decoding Library

A comprehensive image decoding library written entirely in MoonBit, supporting multiple popular image formats with zero external dependencies.

## Supported Formats

| Format | Status | Description |
|--------|--------|-------------|
| **BMP** | ✅ Complete | 1/4/8/24/32-bit, top-down & bottom-up |
| **QOI** | ✅ Complete | RGB & RGBA, full spec compliance |
| **TGA** | ✅ Complete | Uncompressed & RLE, 8/16/24/32-bit |
| **PNG** | ✅ Complete | 8-bit grayscale/RGB/RGBA, indexed, Adam7, full DEFLATE |
| **GIF** | ✅ Complete | GIF87a/89a, LZW decompression, interlace, transparency |
| **JPEG** | ✅ Baseline | Grayscale + YCbCr color, DCT/IDCT, Huffman |

## Installation

```bash
moon add shunge/image
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
pub fn decode_gif(data : Bytes) -> Image raise Failure
pub fn decode_jpeg(data : Bytes) -> Image raise Failure
pub fn decode_gif_all(data : Bytes) -> AnimatedImage raise Failure  // animated GIF
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
shunge/image
├── lib.mbt                    # Main entry: format detection + dispatch
├── types.mbt                  # Core types: Image, Color, PixelFormat, BitReader
├── utils.mbt                  # Byte reading utilities, CRC32, Adler32
├── color.mbt                  # IDCT, YCbCr→RGB color conversion
├── transform.mbt              # Image transform utilities (crop/flip/resize/rotate)
│
├── bmp.mbt                    # BMP decoder
├── qoi.mbt                    # QOI decoder
├── tga.mbt                    # TGA decoder
├── png.mbt                    # PNG decoder + DEFLATE decompressor
├── gif.mbt                    # GIF decoder + LZW decompressor
├── jpeg.mbt                   # JPEG baseline decoder (DCT/IDCT/Huffman)
│
├── bmp_writer.mbt             # BMP encoder
├── qoi_writer.mbt             # QOI encoder
│
├── image_test.mbt             # Core tests: format-specific decoders + error paths
├── medium_image_test.mbt      # Medium-size tests: 64×64 images
├── complex_image_test.mbt     # Complex pattern tests: 128×128 checkerboard, noise, Mandelbrot
├── comprehensive_test.mbt     # Comprehensive tests: GIF/JPEG features, animated GIF, errors
├── fuzz_test.mbt              # Fuzz testing (random bytes → decoders, must not crash)
├── roundtrip_test.mbt         # Round-trip encode/decode tests
├── jpeg_real_test.mbt         # Real JPEG photo tests (11 photos, decode_jpeg verification)
│
├── example/                   # CLI example: image_info
├── tools/                     # Test image generation scripts
├── test_images/               # Test images (up to 2048×2048 + real photos)
├── ARTICLE.md                 # Article: hand-writing DEFLATE in MoonBit
└── LICENSE                    # MIT
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

## Supported GIF Features

- GIF87a and GIF89a formats
- LZW decompression with variable-length codes (up to 12 bits)
- Global and local color tables
- 4-pass interlacing
- Transparency via Graphic Control Extension
- Output format: RGBA8 (palette expansion)

## Supported JPEG Features

- Baseline JPEG (SOF0) with 8-bit precision
- Grayscale (Gray8) and YCbCr color (RGB8) images
- Huffman-coded DC and AC coefficients with O(1) prefix table lookup
- Zigzag deordering, dequantization, and IDCT
- Sub-sampling: 4:4:4, 4:2:2, 4:2:0
- Restart marker (RST) support
- Output formats: Gray8 / RGB8

### Limitations (Future Work)

- JPEG progressive mode (baseline only)
- 16-bit per channel depth (currently 8-bit only)
- Lossless JPEG support
- Arithmetic coding in JPEG
- Ancillary chunk parsing (gAMA, cHRM, sRGB, etc.)
- Streaming/incremental decode
- Image encoders for PNG/JPEG/GIF/TGA (BMP and QOI encoding available)

## License

MIT

## Testing

The project includes 108 tests across 6 test files:

```bash
moon test   # Run all 108 tests
```

Tests cover:
- **Basic decoding** (2×2 ~ 16×16): format-specific decoder correctness for BMP/TGA/QOI/PNG/GIF/JPEG
- **Error handling** (14 tests): truncated data, invalid magic bytes, CRC mismatches, corrupted streams
- **Fuzz testing** (9 tests): random byte sequences fed to each decoder — must not crash
- **Round-trip tests** (17 tests): encode → decode → verify identity for BMP/QOI/TGA
- **Medium images** (64×64): full pixel checksum verification for BMP/TGA/PNG/QOI
- **Complex patterns** (128×128): checkerboard, noise, radial gradient, Mandelbrot fractal — stresses DEFLATE, RLE, and Huffman decoding
- **Comprehensive format tests** (20 tests): PNG filters, multi-IDAT, Adam7, GIF interlace/transparency/animation, JPEG subsampling
- **Real photo JPEG tests** (11 tests): `decode_jpeg()` on embedded JPEG thumbnails of real-world photos (1080p–1706px) with pixel-accurate checksums
- **Large images** (up to 2048×2048): verified via Python/PIL reference decoder

## Contributing

This library aims to build out the MoonBit image processing ecosystem. Planned future additions:
- Additional formats (WebP, TIFF, AVIF)
- Image processing operations (resize, rotate, filters)
- CLI/Web demo application
