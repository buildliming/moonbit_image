// Decode an embedded image through the public API on any supported backend.
// Usage: moon run example --target wasm-gc

///|
fn main raise {
  // A 1x1 QOI image containing one opaque red pixel.
  let data = b"qoif\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00\xFE\xFF\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"
  let img = @image.decode(data)
  assert_eq((img.width, img.height), (1, 1))
  println("Image: \{img.width} x \{img.height}")
  println("Format: \{@image.pixel_format_name(img.format)}")
  let pixel = img.get_pixel(0, 0)
  assert_eq((pixel.r, pixel.g, pixel.b, pixel.a), (255, 0, 0, 255))
  println("Pixel: R=\{pixel.r} G=\{pixel.g} B=\{pixel.b} A=\{pixel.a}")
}
