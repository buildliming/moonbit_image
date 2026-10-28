"""Read embedded fixtures and compact their representation without changing bytes.

Run `python -B tools/fixture_data.py` after regenerating legacy complex/medium
fixtures. Photographic generation already uses this encoding. Standard library
only; source images and independent expected pixels remain embedded in tests.
"""
import base64
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
COMPACT_FILES = (
    "complex_image_test.mbt", "medium_image_test.mbt",
    "real_photo_test.mbt", "jpeg_real_test.mbt",
)
FUNCTIONS = re.compile(
    r'fn (make_\w+)\(\) -> Bytes \{\s*'
    r'(?:make_bytes\(\[(.*?)\]\)|b"(.*?)"|'
    r'fixture_base64\(\s*\(?\s*("[A-Za-z0-9+/=]*"|(?:#\|[A-Za-z0-9+/=]*\s*)+)\s*\)?\s*,?\s*\))\s*\}', re.S)
LARGE_DATA = re.compile(
    r'make_bytes\(\[([\s\S]*?)\]\)|b"((?:\\x[0-9a-fA-F]{2}){128,})"')


def fixture_expression(data: bytes) -> str:
    encoded = base64.b64encode(data).decode("ascii")
    lines = [encoded[i:i + 120] for i in range(0, len(encoded), 120)] or [""]
    return 'fixture_base64((\n' + ''.join('    #|' + line + '\n' for line in lines) + '  ))'


def literal_bytes(array: str, literal: str) -> bytes:
    if array:
        if re.sub(r'0x[0-9a-fA-F]{2}|[\s,]', '', array):
            raise ValueError("Unsupported expression in fixture array")
        return bytes(int(value, 16) for value in re.findall(r'0x([0-9a-fA-F]{2})', array))
    if re.sub(r'\\x[0-9a-fA-F]{2}', '', literal):
        raise ValueError("Unsupported escape in fixture literal")
    return bytes.fromhex(literal.replace('\\x', ''))


def fixture_functions(source: str):
    for name, array, literal, encoded in FUNCTIONS.findall(source):
        compact = ''.join(re.findall(r'[A-Za-z0-9+/=]+', encoded))
        data = (base64.b64decode(compact, validate=True) if encoded else
                literal_bytes(array, literal))
        yield name, data


def compact_source(source: str) -> str:
    def replace(match):
        data = literal_bytes(match.group(1) or "", match.group(2) or "")
        return fixture_expression(data)
    source = LARGE_DATA.sub(replace, source)
    return re.sub(r'fixture_base64\(\s*("[A-Za-z0-9+/=]*"|(?:#\|[A-Za-z0-9+/=]*\s*)+)\s*,?\s*\)',
                  lambda match: fixture_expression(base64.b64decode(
                      ''.join(re.findall(r'[A-Za-z0-9+/=]+', match.group(1))), validate=True)), source)


if __name__ == "__main__":
    for name in COMPACT_FILES:
        path = ROOT / name
        original = path.read_text(encoding="utf-8")
        compact = compact_source(original)
        # Check source-image bytes as well as relying on unchanged test assertions.
        if list(fixture_functions(original)) != list(fixture_functions(compact)):
            raise RuntimeError(f"Fixture bytes changed: {name}")
        if compact != original:
            path.write_text(compact, encoding="utf-8")
        print(f"{name}: {len(original)} -> {len(compact)} characters; fixture bytes preserved")
