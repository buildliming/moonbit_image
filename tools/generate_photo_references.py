"""Replace self-derived photographic checksums with independent Pillow pixels.

Uses only embedded fixture bytes tracked in the repository, so no originals or
network are required. Regenerates both photo suites plus their shared assertions.
Run with Pillow, then run moon fmt. Never reads output from the MoonBit decoder.
"""
from io import BytesIO
from pathlib import Path
from pillow_reference import reference_rgba
from fixture_data import fixture_expression, fixture_functions

ROOT = Path(__file__).resolve().parents[1]


def bytes_function(name, data):
    return f'///|\nfn {name}() -> Bytes {{\n  {fixture_expression(data)}\n}}\n'


def main():
    count = 0
    for filename in ("jpeg_real_test.mbt", "real_photo_test.mbt"):
        path = ROOT / filename
        original = path.read_text(encoding="utf-8")
        entries = list(fixture_functions(original))
        if not entries:
            raise RuntimeError(f"No fixture functions found in {filename}")
        text = "// Photographic fixtures checked against Pillow, not the decoder under test.\n"
        text += "// Regenerate with tools/generate_photo_references.py, then moon fmt.\n\n"
        for function, data in entries:
            if not data:
                raise RuntimeError(function)
            image = reference_rgba(data)
            # Legacy fixtures used eight zero bytes instead of the QOI end
            # marker. Re-encode their independently decoded pixels with Pillow
            # so the positive corpus contains conforming, reusable files.
            if data[:4] == b"qoif" and data[-8:] != b"\x00" * 7 + b"\x01":
                encoded = BytesIO()
                image.save(encoded, format="QOI")
                data = encoded.getvalue()
            jpeg = data[:2] == b"\xff\xd8"
            text += bytes_function(function, data) + "\n"
            text += f'''///|
test "{function.removeprefix('make_')}" {{
  let image = @image.decode({function}())
  assert_eq(image.width, {image.width})
  assert_eq(image.height, {image.height})
  photo_reference_compare(image.to_rgba8().data, '''
            text += fixture_expression(image.tobytes())
            text += f', {3 if jpeg else 0})\n}}\n\n'
            count += 1
        path.write_text(text, encoding="utf-8")
    (ROOT / "photo_reference_helpers_test.mbt").write_text('''// Independent reference assertions shared by both photographic test suites.
///|
fn photo_reference_compare(actual : Bytes, expected : Bytes, tolerance : Int) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i = 0; i < expected.length(); i = i + 1 {
    let difference = actual[i].to_int() - expected[i].to_int()
    if difference < -tolerance || difference > tolerance {
      fail("Reference pixel mismatch at byte \\{i}: actual \\{actual[i]}, expected \\{expected[i]}")
    }
  }
}
''', encoding="utf-8")
    print(f"Regenerated {count} independent photographic tests")


if __name__ == "__main__":
    main()
