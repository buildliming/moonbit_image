# image - Pure MoonBit Image Decoding Library

A pure MoonBit image decoding library with no external runtime dependencies.
Supported inputs and intentional limits are listed below; unsupported variants
and malformed data raise `Failure`.

## Supported Formats

| Format | Supported input |
|--------|-----------------|
| **BMP** | 1/4/8-bit indexed, 24-bit BGR, 32-bit BGRA; RLE4/RLE8; selected 32-bit BITFIELDS layouts |
| **QOI** | RGB/RGBA headers, all six chunk types, RGBA8 output |
| **TGA** | Types 2/3/10/11, truecolor 16/24/32-bit and grayscale 8/16-bit, four image origins |
| **PNG** | Standard color/depth combinations, tRNS, Adam7, stored/fixed/dynamic DEFLATE |
| **GIF** | GIF87a/89a, LZW, interlace, transparency and composited animation frames |
| **JPEG** | 8-bit SOF0 baseline and SOF2 progressive, grayscale and conventional YCbCr 4:4:4/4:2:2/4:2:0 |

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
  println("Format: \{@image.pixel_format_name(img.format)}")
  
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

// Check if the header resembles a supported format; this does not validate pixels
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
├── jpeg.mbt                   # JPEG baseline/progressive decoder (DCT/IDCT/Huffman)
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
├── jpeg_real_test.mbt         # Embedded JPEG photographs with Pillow reference pixels
├── jpeg_progressive_test.mbt  # Spectral selection, refinement, restart and malformed scans
├── real_photo_test.mbt        # Embedded photographs in BMP/PNG/TGA/QOI/GIF
├── *_regression_test.mbt      # Format-specific independent pixel and malformed-input cases
├── decoder_stability_test.mbt # Structured malformed-input stability checks
│
├── example/                   # CLI example: image_info
├── tools/                     # Test image generation scripts
├── test_images/               # Test images (up to 2048×2048 + real photos)
├── ARTICLE.md                 # Article: hand-writing DEFLATE in MoonBit
└── LICENSE                    # MIT
```

## Supported BMP Features

- DIB header sizes 40, 52, 56, 108 and 124 bytes
- 32-bit BGRA (uncompressed and canonical byte-aligned BITFIELDS masks)
- 24-bit BGR (uncompressed)
- 1/4/8-bit indexed images, respecting `biClrUsed` and actual palette extent
- RLE4/RLE8 encoded runs, absolute runs, deltas, word padding and end markers
- Top-down and bottom-up uncompressed rows; compressed images must be bottom-up
- Checked header/pixel offsets, planes, compression/depth combinations and row strides

32-bit input preserves the stored alpha byte, including BI_RGB input. Pixels
omitted by RLE deltas retain the existing transparent fill. Palette entries are
opaque. BITMAPCOREHEADER/OS/2, 16-bit BMP, arbitrary BITFIELDS masks and embedded
JPEG/PNG compression are not supported.

## Supported QOI Features

- RGB (3-channel) and RGBA (4-channel)
- All QOI chunk types: INDEX, DIFF, LUMA, RUN, RGB, RGBA
- The 64-entry color cache, channel wraparound and bounded run lengths
- Header channel/colorspace validation and required eight-byte end marker
- RGBA8 output regardless of the informative header channel count

Colorspace metadata is accepted without performing a color conversion. Truncated
chunks, runs beyond the declared dimensions and extra pixel chunks are rejected.

## Supported TGA Features

- Types 2/10: raw/RLE truecolor at 16/24/32 bits per pixel
- Types 3/11: raw/RLE grayscale at 8 bits, or grayscale+alpha at 16 bits
- All four horizontal/vertical origins, normalized to top-left output
- 16-bit BGR555 with an optional one-bit attribute; truecolor output is RGBA8
- Checked image ID/color-map extents, descriptors, packet sizes and pixel counts

Color-mapped image types 1/9 and interleaved storage are not supported. An unused
color map attached to a supported truecolor/grayscale image is skipped. TGA 2.0
extension metadata and color correction are not interpreted.

## Supported PNG Features

- All standard color/depth combinations: grayscale (1/2/4/8/16-bit), indexed (1/2/4/8-bit), RGB/RGBA/grayscale+alpha (8/16-bit)
- Packed grayscale samples expand to Gray8; 16-bit samples use their high byte to fit the existing 8-bit pixel formats
- tRNS transparency for grayscale, RGB and indexed images, including partial palette alpha tables; transparent colors are compared at original precision
- Full DEFLATE decompression (RFC 1951)
  - Uncompressed blocks (BTYPE=0)
  - Fixed Huffman codes (BTYPE=1)
  - Dynamic Huffman codes (BTYPE=2)
- All five PNG filter types: None, Sub, Up, Average, Paeth
- zlib wrapper (RFC 1950) with header, window-size and Adler32 verification
- Multiple DEFLATE blocks with preserved bit alignment and cross-block back-references
- CRC32 verification for critical chunks and tRNS, chunk ordering/length checks, and palette index validation
- Adam7 interlaced images at every supported depth, including narrow images and empty passes
- Checked image/scanline sizes and decompression bounded by the expected filtered image size

PNG decoding preserves the public API. Grayscale images with tRNS output GrayA8,
RGB images with tRNS output RGBA8, and indexed images always output RGBA8.
16-bit input is decoded to 8-bit output; retaining 16-bit sample precision requires
a future extension to PixelFormat. Color management and APNG animation are not implemented.

## Supported GIF Features

- GIF87a and GIF89a formats
- LZW decompression with variable-length codes (up to 12 bits)
- Global and local color tables
- 4-pass interlacing
- Transparency via Graphic Control Extension
- Logical-screen composition, frame rectangles and disposal methods 0 through 3
- Frame delays and NETSCAPE/ANIMEXTS loop metadata
- Output format: RGBA8 (palette expansion)

`decode_gif()` returns the first composited frame; `decode_gif_all()` returns
composited frames and delays. Plain-text rendering is not supported. Invalid
palettes, frame bounds, LZW streams, plain-text blocks and unsupported disposal
methods raise `Failure`.

## Supported JPEG Features

- Baseline JPEG (SOF0) and progressive JPEG (SOF2) with 8-bit samples and quantization tables
- Grayscale (Gray8) and conventional YCbCr color (RGB8); baseline uses a single scan
- Progressive DC/AC spectral selection, initial scans and successive approximation
- Huffman-coded coefficients using compact canonical tables (at most 304 integers per table)
- Zigzag deordering, dequantization, and IDCT
- Sub-sampling: 4:4:4, 4:2:2, 4:2:0
- Restart marker (RST) support
- Grayscale sampling factors 1 through 4, normalized to noninterleaved blocks
- APPn/COM metadata segments before or after the scan
- Checked segment/table/scan structure, entropy padding and restart sequence
- Output formats: Gray8 / RGB8

Three-component input uses conventional component IDs 1/2/3 for Y/Cb/Cr.
Extended sequential, lossless, arithmetic-coded, CMYK/YCCK, Adobe RGB-transform,
16-bit quantization tables and separate baseline component scans are not supported.
Progressive input is decoded to its final image; incremental preview delivery is
not implemented. DC-only images at EOI are accepted with omitted AC coefficients
set to zero, without libjpeg's optional preview smoothing. JPEG pixels can differ
slightly from libjpeg/Pillow because of IDCT and color rounding.

## Resource Limits

Decoder dimensions and buffer sizes are checked before allocation. Each checked
decoded pixel buffer is limited to 256 MiB (268,435,456 bytes); PNG also limits
the expected filtered scanline buffer, inflation output and cumulative IDAT
payload to 256 MiB each. GIF animation output additionally limits the sum of
retained full-canvas frame bytes to 256 MiB. Progressive JPEG checks a combined
256 MiB logical budget for coefficients, component planes and output buffers;
entropy data has a separate 256 MiB limit per scan.

BMP/QOI/TGA transfer their completed output buffer without a full-image copy;
TGA RLE packets reference their source bytes directly. PNG reverses filters using
two reusable rows per pass and writes directly to the final output, including
Adam7. GIF transfers the first-frame canvas directly or copies it once per
retained animation frame, preserving frame independence.

These are logical buffer limits, not a process-wide memory budget. Input bytes,
temporary compressed buffers, runtime array/object overhead and later image
transformations consume additional memory. Exceeding a decoder limit raises
`Failure`.

## Other Limitations

- Preserving 16-bit PNG output precision (PNG input is supported and reduced to 8-bit samples)
- PNG color management (gAMA/cHRM/sRGB/ICC) and APNG animation
- Streaming/incremental decode
- Image encoders for PNG/JPEG/GIF/TGA (BMP and QOI encoding available)
- Formats such as WebP, TIFF and AVIF

## License

MIT

## Testing

Starting with 0.2.1, the Mooncakes download includes the full test suite, embedded
image samples, independent expected pixels and Python reference/generation tools.
Run the commands below from an extracted package or a checkout of the
[source repository](https://github.com/buildliming/moonbit_image). No original
photo downloads are needed. The largest fixtures use compact Base64 storage;
MoonBit's standard library restores exactly the original bytes during tests,
independently of the image decoder. Tests need no Python or runtime file access.
Only generated images, build output and local caches are excluded from publishing.

Run strict checks without warning suppression:

```bash
moon check --deny-warn
moon fmt --check
moon info
moon test --deny-warn --target wasm-gc
moon test --deny-warn --target js
moon test --deny-warn --target native
```

In a Git checkout, also run `git diff --exit-code -- pkg.generated.mbti` after
`moon info` to check for unintended public API changes.

CI runs the wasm-gc, JavaScript and native targets on Linux. Compiler and core
are pinned together to `0.10.14+7d59c7ec9`; the reference job uses Node.js 24,
Python 3.12 and Pillow 12.3.0. Native tests require a supported local C toolchain.

Tests cover exact decoded pixels, row padding, origins, palette/transparency
handling, PNG filters/Adam7/DEFLATE, GIF composition, JPEG sampling/restarts and
progressive refinement,
malformed structures, resource limits and deterministic input mutation. Existing
round-trip and pattern tests complement independent reference cases.

The photographic test suites use embedded image bytes and Pillow-derived pixel
expectations instead of decoder-derived checksums. Lossless comparisons are
exact; JPEG comparisons allow a documented per-channel rounding tolerance.
Regeneration also repairs invalid legacy QOI end markers.

For a reusable comparison against an independent decoder, install Pillow and run:

```bash
python -m pip install Pillow==12.3.0
python -B -m unittest discover -s tools -p test_pillow_reference.py
python tools/verify_decoders.py
python tools/verify_decoders.py --suite basic
python tools/verify_decoders.py --corpus /path/to/photos --max-side 128
```

The verifier builds the actual MoonBit decoder for JavaScript and compares its
RGBA bytes against Pillow. Embedded photographic JPEGs and optional corpus files
are first compared directly, preserving original dimensions and encoding
features. Unsupported, unreadable or corrupt originals are recorded as failures;
the verifier continues with other files and writes its report before returning
a failure status. The default complex suite derives Gaussian blur (two radii),
box blur and horizontal motion blur from those photographs and deterministic
patterns: smooth gradients, radial alpha, high-frequency patterns, odd dimensions
and one-pixel-wide images. Its encoding matrix covers all six formats, including
baseline/progressive JPEG 4:4:4, 4:2:2 and 4:2:0, TGA RLE and GIF interlacing.
The default corpus has 1311 comparisons, including 300 progressive JPEG cases.
`--suite basic` selects the smaller 131-case matrix. `--max-side` bounds derived
cases; original-file comparisons keep their full dimensions.

The verifier reuses one Node process and one input/output file pair, processes
one source at a time, and removes its temporary build directory after the run.
`--timeout` bounds each decoder request (30 seconds by default); a timeout or
process crash is recorded and the worker restarts for subsequent cases.

`tools/pillow_reference.py` supplements Pillow for PNG normalization and
transparency cases that Pillow's RGBA conversion does not preserve: 16-bit
grayscale uses the high byte rather than clamping, and grayscale/RGB `tRNS`
comparisons use original sample precision, masking unused key bits according to
the PNG specification. These expectations come from an independent Python
implementation of zlib inflation, PNG filters and Adam7 sample extraction,
followed by specification-defined normalization; they never use MoonBit decoder
output. Python tests cover normalization, transparency precision, interlacing,
blur and encoding variants, continued processing after bad original files and
worker recovery after a failure, crash or timeout.

Lossless results must match exactly; JPEG allows at most three levels of error
per channel. The JSON report `_build/decoder-reference-results.json` remains
local; no network is required. Failed encoded inputs are retained by SHA256 in
`_build/decoder-reference-failures/`; successful temporary inputs are removed.
The report records Pillow version, dimensions, encoding and blur parameters,
input hashes, pixel errors and elapsed decoder time. These
cases complement the format-specific fixtures rather than establishing support
for every variant of a format.

Regenerate the independent fixtures from the repository root, then format and
rerun the tests. PNG generators use Python's standard library; the remaining
generators require Pillow:

```bash
python tools/generate_png_regression_fixtures.py
python tools/generate_png_deflate_fixtures.py
python tools/generate_bmp_regression_fixtures.py
python tools/generate_gif_regression_fixtures.py
python tools/generate_jpeg_regression_fixtures.py
python tools/generate_jpeg_progressive_fixtures.py
python tools/generate_qoi_tga_fixtures.py
python tools/generate_photo_references.py
python -B tools/fixture_data.py
moon fmt
moon test --deny-warn
```

Some fixtures assert specification behavior that differs from Pillow: odd RLE4
absolute runs are checked through equivalent uncompressed reference images;
32-bit BMP alpha and skipped RLE pixels retain this library's documented behavior.
These exceptions are identified in their generators.

`tools/fixture_data.py` also compacts legacy complex/medium fixture output without
changing its bytes. Photographic generators write the compact form directly;
the independent verifier reads both the legacy and compact forms. The supported
reproduction commands above use the embedded samples and work from the package;
historical root-level generation scripts are not required for reproduction.

PNG behavior follows the [W3C PNG specification](https://www.w3.org/TR/png-3/),
[RFC 1950](https://www.rfc-editor.org/rfc/rfc1950) and
[RFC 1951](https://www.rfc-editor.org/rfc/rfc1951).
Progressive JPEG scan handling follows
[ITU-T T.81 Annex G](https://www.w3.org/Graphics/JPEG/itu-t81.pdf).

## Contributing

This library aims to build out the MoonBit image processing ecosystem. Planned future additions:
- Additional formats (WebP, TIFF, AVIF)
- Additional image processing filters (resize and rotation already exist)
- CLI/Web demo application
