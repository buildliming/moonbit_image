// Copyright (c) 2025 lws
// Image decoding tests
//
// Tests for BMP, TGA, QOI, and PNG decoding with known test images.
// Each test image is a 2x2 pixel image with known color patterns.

//-----------------------------------------------------------------------------
// Helper: create Bytes from integer array
//-----------------------------------------------------------------------------

fn make_bytes(ints : Array[Int]) -> Bytes {
  let arr = Array::make(ints.length(), b'\x00')
  for i = 0; i < ints.length(); i = i + 1 {
    arr[i] = ints[i].to_byte()
  }
  Bytes::from_array(arr)
}

//-----------------------------------------------------------------------------
// Test helper functions
//-----------------------------------------------------------------------------

/// Verify that a decoded image has the expected dimensions
fn check_dims(img : Image, expected_w : Int, expected_h : Int) -> Unit raise Failure {
  if img.width != expected_w {
    raise Failure::Failure("Expected width \{expected_w}, got \{img.width}")
  }
  if img.height != expected_h {
    raise Failure::Failure("Expected height \{expected_h}, got \{img.height}")
  }
  ()
}

/// Verify a pixel's RGBA color
fn check_pixel(img : Image, x : Int, y : Int, r : Int, g : Int, b : Int, a : Int) -> Unit raise Failure {
  let c = img.get_pixel(x, y)
  if c.r != r || c.g != g || c.b != b || c.a != a {
    raise Failure::Failure("Pixel (\{x},\{y}): expected (\{r},\{g},\{b},\{a}), got (\{c.r},\{c.g},\{c.b},\{c.a})")
  }
  ()
}

//-----------------------------------------------------------------------------
// Test BMP 2x2 24-bit BGR (bottom-up)
// Pixels (top->bottom, left->right):
//   Row 0: Red(255,0,0), Green(0,255,0)
//   Row 1: Blue(0,0,255), White(255,255,255)
//-----------------------------------------------------------------------------

fn make_test_bmp() -> Bytes {
  make_bytes([
    0x42, 0x4D, // BM signature
    0x46, 0x00, 0x00, 0x00, // file size = 70
    0x00, 0x00, // reserved
    0x00, 0x00, // reserved
    0x36, 0x00, 0x00, 0x00, // data offset = 54
    // DIB header
    0x28, 0x00, 0x00, 0x00, // header size = 40
    0x02, 0x00, 0x00, 0x00, // width = 2
    0x02, 0x00, 0x00, 0x00, // height = 2
    0x01, 0x00, // planes = 1
    0x18, 0x00, // bpp = 24
    0x00, 0x00, 0x00, 0x00, // BI_RGB
    0x10, 0x00, 0x00, 0x00, // image size = 16
    0x13, 0x0B, 0x00, 0x00, // h-res
    0x13, 0x0B, 0x00, 0x00, // v-res
    0x00, 0x00, 0x00, 0x00, // colors
    0x00, 0x00, 0x00, 0x00, // important
    // Row 0 (bottom): Red, Green
    0x00, 0x00, 0xFF, // Red: B=0,G=0,R=255
    0x00, 0xFF, 0x00, // Green: B=0,G=255,R=0
    0x00, 0x00, // padding
    // Row 1 (top): Blue, White
    0xFF, 0x00, 0x00, // Blue: B=255,G=0,R=0
    0xFF, 0xFF, 0xFF, // White
    0x00, 0x00, // padding
  ])
}

test "decode_bmp_24bit" {
  let data = make_test_bmp()
  let img = decode_bmp(data)
  check_dims(img, 2, 2)

  // Row 0 (top): Blue, White (BMP stores bottom-up, top row in file becomes row 0)
  check_pixel(img, 0, 0, 0, 0, 255, 255)
  check_pixel(img, 1, 0, 255, 255, 255, 255)
  // Row 1 (bottom): Red, Green
  check_pixel(img, 0, 1, 255, 0, 0, 255)
  check_pixel(img, 1, 1, 0, 255, 0, 255)
  println("BMP 24-bit test passed!")
}

//-----------------------------------------------------------------------------
// Test TGA 2x2 24-bit uncompressed (Type 2, top-left origin)
// Pixels (top->bottom, left->right):
//   Row 0: Red(255,0,0), Green(0,255,0)
//   Row 1: Blue(0,0,255), White(255,255,255)
//-----------------------------------------------------------------------------

fn make_test_tga() -> Bytes {
  make_bytes([
    0x00, // ID length = 0
    0x00, // color map type = none
    0x02, // image type = uncompressed true-color
    // Color map spec (5 bytes)
    0x00, 0x00, // first entry
    0x00, 0x00, // length
    0x00, // entry size
    // Image spec (10 bytes)
    0x00, 0x00, // x-origin
    0x00, 0x00, // y-origin
    0x02, 0x00, // width = 2
    0x02, 0x00, // height = 2
    0x18, // pixel depth = 24
    0x20, // descriptor: top-left origin, 0 alpha bits
    // Pixel data (BGR order, top->bottom)
    0x00, 0x00, 0xFF, // Red: B=0,G=0,R=255
    0x00, 0xFF, 0x00, // Green: B=0,G=255,R=0
    0xFF, 0x00, 0x00, // Blue: B=255,G=0,R=0
    0xFF, 0xFF, 0xFF, // White
  ])
}

test "decode_tga_type2" {
  let data = make_test_tga()
  let img = decode_tga(data)
  check_dims(img, 2, 2)

  // Top row (row 0): Red, Green
  check_pixel(img, 0, 0, 255, 0, 0, 255)
  check_pixel(img, 1, 0, 0, 255, 0, 255)
  // Bottom row (row 1): Blue, White
  check_pixel(img, 0, 1, 0, 0, 255, 255)
  check_pixel(img, 1, 1, 255, 255, 255, 255)
  println("TGA type 2 test passed!")
}

//-----------------------------------------------------------------------------
// Test QOI 2x2 RGB
// Pixels (row-major): Red, Green, Blue, White
//-----------------------------------------------------------------------------

fn make_test_qoi() -> Bytes {
  make_bytes([
    0x71, 0x6F, 0x69, 0x66, // "qoif"
    0x00, 0x00, 0x00, 0x02, // width = 2 (BE)
    0x00, 0x00, 0x00, 0x02, // height = 2 (BE)
    0x03, // channels = RGB
    0x00, // colorspace = sRGB
    // Pixel 0: Red (QOI_OP_RGB + R,G,B)
    0xFE, 0xFF, 0x00, 0x00,
    // Pixel 1: Green
    0xFE, 0x00, 0xFF, 0x00,
    // Pixel 2: Blue
    0xFE, 0x00, 0x00, 0xFF,
    // Pixel 3: White
    0xFE, 0xFF, 0xFF, 0xFF,
    // End marker
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
  ])
}

test "decode_qoi_rgb" {
  let data = make_test_qoi()
  let img = decode_qoi(data)
  check_dims(img, 2, 2)

  // Row-major: Red, Green, Blue, White
  check_pixel(img, 0, 0, 255, 0, 0, 255)
  check_pixel(img, 1, 0, 0, 255, 0, 255)
  check_pixel(img, 0, 1, 0, 0, 255, 255)
  check_pixel(img, 1, 1, 255, 255, 255, 255)
  println("QOI RGB test passed!")
}

//-----------------------------------------------------------------------------
// Test PNG 2x2 grayscale (8-bit)
// Pixels (row-major): 0, 85, 170, 255
// This tests: zlib decompression, fixed Huffman, filter None
//-----------------------------------------------------------------------------

fn make_test_png() -> Bytes {
  make_bytes([
    // PNG signature
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    // IHDR chunk
    0x00, 0x00, 0x00, 0x0D, // length = 13
    0x49, 0x48, 0x44, 0x52, // "IHDR"
    0x00, 0x00, 0x00, 0x02, // width = 2
    0x00, 0x00, 0x00, 0x02, // height = 2
    0x08, // bit depth = 8
    0x00, // color type = grayscale
    0x00, // compression
    0x00, // filter
    0x00, // interlace
    0x57, 0xDD, 0x52, 0xF8, // CRC32
    // IDAT chunk
    0x00, 0x00, 0x00, 0x0E, // length = 14
    0x49, 0x44, 0x41, 0x54, // "IDAT"
    // zlib data (CMF=0x78, FLG=0x9C, deflate + adler32)
    0x78, 0x9C, 0x63, 0x60, 0x08, 0x65, 0x58, 0xF5, 0x1F, 0x00, 0x03, 0xAD, 0x01, 0xFF,
    0x67, 0xFB, 0xCA, 0x09, // CRC32
    // IEND chunk
    0x00, 0x00, 0x00, 0x00, // length = 0
    0x49, 0x45, 0x4E, 0x44, // "IEND"
    0xAE, 0x42, 0x60, 0x82, // CRC32
  ])
}

test "decode_png_grayscale" {
  let data = make_test_png()
  let img = decode_png(data)
  check_dims(img, 2, 2)

  // Pixels: 0, 85, 170, 255
  check_pixel(img, 0, 0, 0, 0, 0, 255)
  check_pixel(img, 1, 0, 85, 85, 85, 255)
  check_pixel(img, 0, 1, 170, 170, 170, 255)
  check_pixel(img, 1, 1, 255, 255, 255, 255)
  println("PNG grayscale test passed!")
}

//-----------------------------------------------------------------------------
// Test format detection
//-----------------------------------------------------------------------------

test "format_detection" {
  // BMP detection
  let bmp = make_test_bmp()
  match detect_format(bmp) {
    Some(_) => ()
    _ => raise Failure::Failure("BMP not detected correctly")
  }

  // TGA detection
  let tga = make_test_tga()
  match detect_format(tga) {
    Some(_) => ()
    _ => raise Failure::Failure("TGA not detected correctly")
  }

  // QOI detection
  let qoi = make_test_qoi()
  match detect_format(qoi) {
    Some(_) => ()
    _ => raise Failure::Failure("QOI not detected correctly")
  }

  // PNG detection
  let png = make_test_png()
  match detect_format(png) {
    Some(_) => ()
    _ => raise Failure::Failure("PNG not detected correctly")
  }

  // is_supported_format
  if !(is_supported_format(bmp)) { raise Failure::Failure("BMP should be supported") }
  if !(is_supported_format(tga)) { raise Failure::Failure("TGA should be supported") }
  if !(is_supported_format(qoi)) { raise Failure::Failure("QOI should be supported") }
  if !(is_supported_format(png)) { raise Failure::Failure("PNG should be supported") }

  // Unknown format
  let junk = make_bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  if is_supported_format(junk) { raise Failure::Failure("Random bytes should not be supported") }

  println("Format detection tests passed!")
}

//-----------------------------------------------------------------------------
// Test unified decode API
//-----------------------------------------------------------------------------

test "unified_decode" {
  // Test auto-detect and decode for each format
  let bmp = make_test_bmp()
  let bmp_img = decode(bmp)
  if bmp_img.width != 2 || bmp_img.height != 2 { raise Failure::Failure("BMP decode dimensions wrong") }

  let tga = make_test_tga()
  let tga_img = decode(tga)
  if tga_img.width != 2 || tga_img.height != 2 { raise Failure::Failure("TGA decode dimensions wrong") }

  let qoi = make_test_qoi()
  let qoi_img = decode(qoi)
  if qoi_img.width != 2 || qoi_img.height != 2 { raise Failure::Failure("QOI decode dimensions wrong") }

  let png = make_test_png()
  let png_img = decode(png)
  if png_img.width != 2 || png_img.height != 2 { raise Failure::Failure("PNG decode dimensions wrong") }

  println("Unified decode API tests passed!")
}

//-----------------------------------------------------------------------------
// Test image_dimensions (header-only, fast)
//-----------------------------------------------------------------------------

test "image_dimensions_fast" {
  let bmp = make_test_bmp()
  let (w, h, _fmt) = image_dimensions(bmp)
  if w != 2 || h != 2 { raise Failure::Failure("BMP dimensions wrong") }

  let tga = make_test_tga()
  let (w2, h2, _fmt2) = image_dimensions(tga)
  if w2 != 2 || h2 != 2 { raise Failure::Failure("TGA dimensions wrong") }

  let qoi = make_test_qoi()
  let (w3, h3, _fmt3) = image_dimensions(qoi)
  if w3 != 2 || h3 != 2 { raise Failure::Failure("QOI dimensions wrong") }

  let png = make_test_png()
  let (w4, h4, _fmt4) = image_dimensions(png)
  if w4 != 2 || h4 != 2 { raise Failure::Failure("PNG dimensions wrong") }

  println("Header-only dimension tests passed!")
}

//-----------------------------------------------------------------------------
// Test to_rgba8 conversion
//-----------------------------------------------------------------------------

test "to_rgba8_conversion" {
  let data = make_test_bmp()
  // Decode as BMP (outputs RGB8 for 24-bit)
  let img = decode_bmp(data)
  if img.width != 2 || img.height != 2 { raise Failure::Failure("BMP decode failed") }

  // Convert to RGBA8
  let rgba = img.to_rgba8()
  if rgba.width != 2 || rgba.height != 2 { raise Failure::Failure("Dimensions changed during conversion") }
  // RGBA8 should have 4 bytes per pixel
  if rgba.bytes_per_pixel() != 4 { raise Failure::Failure("Expected 4 bytes per pixel after conversion") }

  // Check pixels are still correct (same layout as BMP: row 0 = Blue/White, row 1 = Red/Green)
  check_pixel(rgba, 0, 0, 0, 0, 255, 255)
  check_pixel(rgba, 1, 0, 255, 255, 255, 255)
  check_pixel(rgba, 0, 1, 255, 0, 0, 255)
  check_pixel(rgba, 1, 1, 0, 255, 0, 255)
  println("to_rgba8 conversion test passed!")
}
