// Fixture storage only: decoding uses the standard library, independently of
// the image implementation under test. No file access or Python is required.

///|
fn fixture_base64(encoded : String) -> Bytes {
  @base64.decode(encoded, ignore_whitespace=true) catch {
    _ => abort("Invalid Base64 in embedded image test fixture")
  }
}
