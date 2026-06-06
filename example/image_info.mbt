// Image Info CLI — Decode and display image metadata
// Usage: moon run example/image_info.mbt -- <image-file-path>

fn main {
  let args = @args
  if args.length() < 2 {
    println("Usage: moon run example/image_info.mbt -- <image-file>")
    println("Reads an image file and displays its metadata.")
    return
  }

  let path = args[1]
  println("Reading: \{path}")

  // Read file
  match read_file(path) {
    Ok(data) => {
      let img = @image.decode(data)
      println("")
      println("Format:      \{@image.image_format_name(@image.detect_format(data).unwrap())}")
      println("Pixel type:  \{@image.pixel_format_name(img.format)}")
      println("Dimensions:  \{img.width} x \{img.height}")
      println("Total pixels: \{img.width * img.height}")
      println("Bytes/pixel: \{img.bytes_per_pixel()}")
      println("Data size:   \{img.data.length()} bytes")

      // Show first few pixel values
      println("")
      println("Sample pixels (top-left corner):")
      for y = 0; y < if img.height < 3 { img.height } else { 3 }; y = y + 1 {
        for x = 0; x < if img.width < 5 { img.width } else { 5 }; x = x + 1 {
          let c = img.get_pixel(x, y)
          print("  (\{x},\{y})=\{c.r},\{c.g},\{c.b},\{c.a} ")
        }
        println("")
      }

      println("")
      println("Done!")
    }
    Err(e) => println("Error: \{e}")
  }
}

/// Read a file into Bytes
fn read_file(path : String) -> Result[Bytes, String] {
  // Use @fs.read_bytes(path) if available, otherwise fail gracefully
  raise Failure::Failure("File I/O not available in this build target. Use moon build --target native for file I/O.")
}
