"""Compare the actual MoonBit decoder against Pillow on independent image bytes.

Usage: python tools/verify_decoders.py [--corpus DIRECTORY] [--max-side 128]
Requires moon, Node.js and Pillow. No network, machine-specific paths, or project
test-output-derived expectations. Sources/cases/results live under _build.
The default corpus uses embedded photographic JPEGs already tracked in this repo
plus deterministic patterns; --corpus also accepts the user's own photographs.
"""
from __future__ import annotations

import argparse
from io import BytesIO
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from PIL import Image, __version__ as pillow_version
from pillow_reference import reference_rgba

ROOT = Path(__file__).resolve().parents[1]

MAIN = r'''
extern "js" fn read_input() -> Bytes =
  #| () => new Uint8Array(require('node:fs').readFileSync(process.argv[2]))
extern "js" fn emit(w : Int, h : Int, data : Bytes) -> Unit =
  #| (w,h,data) => { require('node:fs').writeFileSync(process.argv[3],data); console.log(JSON.stringify({width:w,height:h})); }
extern "js" fn fail_exit() -> Unit =
  #| () => { process.exitCode = 1; }
fn main {
  try {
    let result = decode(read_input()).to_rgba8()
    emit(result.width, result.height, result.data)
  } catch {
    error => { println(error); fail_exit() }
  }
}
'''


def build_harness(work: Path) -> Path:
    source = work / "decoder"
    source.mkdir()
    for path in ROOT.glob("*.mbt"):
        if not path.name.endswith(("_test.mbt", "_wbtest.mbt")):
            shutil.copy2(path, source / path.name)
    (source / "moon.mod").write_text('name = "local/decoder_reference"\n')
    (source / "moon.pkg").write_text('options(is_main: true)\n')
    (source / "main.mbt").write_text(MAIN, encoding="utf-8")
    subprocess.run(["moon", "build", "--target", "js", "--release"], cwd=source,
                   check=True, timeout=120)
    candidates = list((source / "_build" / "js" / "release" / "build").glob("*.js"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one compiled JavaScript entry, got {candidates}")
    return candidates[0]


def original_images(corpus: Path | None):
    # These are bytes of real photographs, not expected decoder checksums.
    source = (ROOT / "jpeg_real_test.mbt").read_text(encoding="utf-8")
    matches = re.findall(r"fn (make_\w+)\(\) -> Bytes \{\s*(?:make_bytes\(\[(.*?)\]\)|b\"(.*?)\")\s*\}", source, re.S)
    if not matches:
        raise RuntimeError("No photographic fixtures found in jpeg_real_test.mbt")
    for name, payload, literal in matches:
        values = re.findall(r"0x([0-9A-Fa-f]{2})", payload) if payload else re.findall(r"\\x([0-9A-Fa-f]{2})", literal)
        data = bytes(int(value, 16) for value in values)
        yield name, data, None
    if corpus:
        for path in sorted(corpus.rglob("*")):
            if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp", ".tga", ".gif", ".qoi"}:
                name = str(path.relative_to(corpus))
                try:
                    yield name, path.read_bytes(), None
                except OSError as error:
                    yield name, None, str(error)


def source_images(originals, max_side: int):
    for name, data, read_error in originals:
        if read_error is not None:
            continue
        try:
            image = reference_rgba(data)
            image.thumbnail((max_side, max_side))
        except (OSError, ValueError, Image.DecompressionBombError):
            # The original comparison already recorded this source failure.
            # Preserve that row and continue so a complete report is written.
            continue
        yield name, image
    for mode in ("RGB", "RGBA", "L", "LA"):
        image = Image.new(mode, (37, 29))
        bands = len(image.getbands())
        image.putdata([tuple((x * 37 + y * 19 + c * 83) % 256 for c in range(bands))
                       if bands > 1 else (x * 37 + y * 19) % 256
                       for y in range(29) for x in range(37)])
        yield "pattern_" + mode, image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--max-side", type=int, default=128)
    args = parser.parse_args()
    if args.max_side < 1 or args.max_side > 4096:
        parser.error("--max-side must be between 1 and 4096")
    if args.corpus and not args.corpus.is_dir():
        parser.error("--corpus must be an existing directory")
    build = ROOT / "_build"
    build.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="decoder-reference-", dir=build))
    entry = build_harness(work)
    results = []

    def compare(name, encoded, kind, variant=None):
        row = {"source": name, "kind": kind}
        if variant is not None:
            row["subsampling"] = variant
        try:
            with Image.open(BytesIO(encoded)) as input_image:
                fmt = input_image.format
            reference = reference_rgba(encoded)
            row.update(format=fmt, width=reference.width, height=reference.height)
            case_path = work / (str(len(results)) + "." + fmt.lower())
            result_path = work / "pixels.rgba"
            case_path.write_bytes(encoded)
            run = subprocess.run(["node", str(entry), str(case_path), str(result_path)],
                                 capture_output=True, text=True, timeout=30)
            if run.returncode:
                row.update(ok=False, error=(run.stdout + run.stderr)[-1200:])
            else:
                lines = run.stdout.strip().splitlines()
                if not lines:
                    raise ValueError("Decoder returned no JSON metadata")
                meta = json.loads(lines[-1])
                actual = result_path.read_bytes()
                expected = reference.tobytes()
                valid_shape = (meta == {"width": reference.width, "height": reference.height}
                               and len(actual) == len(expected))
                maximum, total_error = 0, 0
                for a, b in zip(actual, expected):
                    difference = abs(a - b)
                    maximum = max(maximum, difference)
                    total_error += difference
                row.update(ok=valid_shape and maximum <= (3 if fmt == "JPEG" else 0),
                           max_error=maximum, mean_error=total_error / max(1, len(expected)))
        except (OSError, ValueError, Image.DecompressionBombError, subprocess.TimeoutExpired) as error:
            row.update(ok=False, error=str(error))
        results.append(row)

    originals = list(original_images(args.corpus))
    # Preserve dimensions, bit depths, palettes and JPEG sampling in this pass.
    # Unsupported originals fail visibly; they are never silently transcoded.
    for name, encoded, read_error in originals:
        if read_error is not None:
            results.append({"source": name, "kind": "original", "ok": False, "error": read_error})
        else:
            compare(name, encoded, "original")
    variants = [(fmt, None) for fmt in ("PNG", "BMP", "TGA", "QOI", "GIF")]
    variants += [("JPEG", sampling) for sampling in (0, 1, 2)]
    for name, image in source_images(originals, args.max_side):
        for fmt, sampling in variants:
            candidate = image
            if fmt in ("BMP", "GIF", "JPEG"):
                candidate = image.convert("RGB")
            elif fmt == "QOI":
                candidate = image.convert("RGBA")
            output = BytesIO()
            # Cover 4:4:4, 4:2:2 and 4:2:0. JPEG permits small IDCT/color
            # rounding differences; all lossless formats require exact pixels.
            kwargs = {"quality": 90, "subsampling": sampling} if fmt == "JPEG" else {}
            candidate.save(output, format=fmt, **kwargs)
            encoded = output.getvalue()
            compare(name, encoded, "generated", sampling)
    report = build / "decoder-reference-results.json"
    report.write_text(json.dumps({"pillow": pillow_version, "cases": results, "passed": sum(r["ok"] for r in results),
                                  "total": len(results)}, indent=2), encoding="utf-8")
    failures = [row for row in results if not row["ok"]]
    for row in failures:
        print(json.dumps(row))
    print(f"Independent reference: {len(results)-len(failures)}/{len(results)} passed; {report}")
    if not results or failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
