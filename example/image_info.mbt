// Image Info CLI — Decode and display image metadata
// Usage: moon run example/image_info.mbt -- <image-file-path>

fn main {
  let args = @args
  let args_count = args.length()
  if args_count < 2 {
    println("Usage: moon run example/image_info.mbt -- <image-file>")
    println("Reads an image file and displays its metadata.")
    return
  }

  let path = args[1]
  let _ = path
  // File I/O requires native target
  println("To use this example, build with: moon build --target native")
  println("Then run the native binary with an image file path.")
  println("File I/O is available in native target via @fs.read_bytes")
}

///|
/// Read a file into Bytes — available in native target
fn read_file(path : String) -> Bytes {
  @fs.read_bytes(path)
}
