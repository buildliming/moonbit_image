"""Compare the actual MoonBit decoder against Pillow on independent image bytes.

Usage: python tools/verify_decoders.py [--corpus DIRECTORY] [--max-side 128]
Requires moon, Node.js and Pillow. No network, machine-specific paths, or project
test-output-derived expectations. Reports and failed inputs live under _build;
temporary build files and successful inputs are removed after each run.
The default corpus uses embedded photographic JPEGs already tracked in this repo
plus deterministic patterns; --corpus also accepts the user's own photographs.
"""
from __future__ import annotations

import argparse
import hashlib
from io import BytesIO
import json
import math
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time

from PIL import Image, ImageFilter, __version__ as pillow_version
from pillow_reference import reference_rgba
from fixture_data import fixture_functions

ROOT = Path(__file__).resolve().parents[1]

MAIN = r'''
extern "js" fn next_input() -> Bool =
  #| () => {
  #|   const fs = require('node:fs');
  #|   globalThis.referenceState ??= {pending: '', chunk: Buffer.alloc(4096)};
  #|   const state = globalThis.referenceState;
  #|   while (!state.pending.includes('\n')) {
  #|     const n = fs.readSync(0, state.chunk, 0, state.chunk.length, null);
  #|     if (!n) return false;
  #|     state.pending += state.chunk.toString('utf8', 0, n);
  #|   }
  #|   const newline = state.pending.indexOf('\n');
  #|   state.request = JSON.parse(state.pending.slice(0, newline));
  #|   state.pending = state.pending.slice(newline + 1);
  #|   state.started = performance.now();
  #|   return true;
  #| }
extern "js" fn read_input() -> Bytes =
  #| () => new Uint8Array(require('node:fs').readFileSync(globalThis.referenceState.request.input))
extern "js" fn emit(w : Int, h : Int, data : Bytes) -> Unit =
  #| (w,h,data) => { const state = globalThis.referenceState; const decode_ms = performance.now() - state.started; require('node:fs').writeFileSync(state.request.output,data); console.log(JSON.stringify({width:w,height:h,decode_ms})); }
extern "js" fn fail(message : String) -> Unit =
  #| message => console.log(JSON.stringify({error:message}))
fn main {
  while next_input() {
    try {
      let result = decode(read_input()).to_rgba8()
      emit(result.width, result.height, result.data)
    } catch {
      error => fail(error.to_string())
    }
  }
}
'''


class DecoderWorker:
    """Reuse one Node process; kill and replace it after a timeout or crash."""

    def __init__(self, entry: Path, work: Path, timeout: float):
        self.entry, self.work, self.timeout = entry, work, timeout
        self.process = None
        self.reader = None

    def _start(self):
        self.responses = queue.Queue()
        self.process = subprocess.Popen(
            ["node", "--max-old-space-size=512", str(self.entry)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8",
        )
        responses, output = self.responses, self.process.stdout

        def read_responses():
            try:
                for line in output:
                    responses.put(line)
            finally:
                responses.put(None)

        self.reader = threading.Thread(target=read_responses, daemon=True)
        self.reader.start()

    def close(self, force=False):
        if self.process is not None:
            if force and self.process.poll() is None:
                self.process.kill()
            try:
                self.process.stdin.close()
            except OSError:
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.reader.join(timeout=2)
            self.process.stdout.close()
            self.process = None

    def decode(self, encoded: bytes):
        if self.process is None:
            self._start()
        input_path, output_path = self.work / "input.image", self.work / "pixels.rgba"
        input_path.write_bytes(encoded)
        output_path.unlink(missing_ok=True)
        try:
            self.process.stdin.write(json.dumps({"input": str(input_path), "output": str(output_path)}) + "\n")
            self.process.stdin.flush()
            try:
                line = self.responses.get(timeout=self.timeout)
            except queue.Empty as error:
                raise TimeoutError(f"Decoder exceeded {self.timeout:g} seconds") from error
            if line is None:
                raise RuntimeError("Decoder process exited without a response")
            metadata = json.loads(line)
            pixels = None if "error" in metadata else output_path.read_bytes()
        except (OSError, ValueError, RuntimeError, TimeoutError):
            # A failed decode cannot leave a stale output or protocol response
            # that is accidentally reused for the next case.
            self.close(force=True)
            raise
        # A recoverable MoonBit Failure leaves the worker ready for another
        # request. Protocol errors, traps, crashes and timeouts restart it.
        if "error" in metadata:
            raise ValueError(metadata["error"])
        return metadata, pixels


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
    matches = list(fixture_functions(source))
    if not matches:
        raise RuntimeError("No photographic fixtures found in jpeg_real_test.mbt")
    for name, data in matches:
        yield name, data, None
    if corpus:
        for path in sorted(corpus.rglob("*")):
            if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp", ".tga", ".gif", ".qoi"}:
                name = str(path.relative_to(corpus))
                try:
                    yield name, path.read_bytes(), None
                except OSError as error:
                    yield name, None, str(error)


def source_images(originals, max_side: int, include_patterns=True):
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
    if not include_patterns:
        return
    for mode in ("RGB", "RGBA", "L", "LA"):
        image = Image.new(mode, (37, 29))
        bands = len(image.getbands())
        image.putdata([tuple((x * 37 + y * 19 + c * 83) % 256 for c in range(bands))
                       if bands > 1 else (x * 37 + y * 19) % 256
                       for y in range(29) for x in range(37)])
        image.thumbnail((max_side, max_side))
        yield "pattern_" + mode, image


def complex_patterns(max_side: int):
    """Small, odd and narrow dimensions exercise row, block and alpha edges."""
    patterns = [
        ("smooth_gradient", "RGB", (65, 33),
         lambda x, y, w, h: (255 * x // max(1, w - 1), 255 * y // max(1, h - 1),
                             255 * (x + y) // max(1, w + h - 2))),
        ("radial_alpha", "RGBA", (31, 47),
         lambda x, y, w, h: (255 * x // max(1, w - 1), 83, 255 * y // max(1, h - 1),
                             min(255, round(255 * math.hypot((2*x-w+1)/w, (2*y-h+1)/h))))),
        ("high_frequency", "RGB", (17, 19),
         lambda x, y, w, h: (255 * ((x+y) % 2), 255 * (x % 2), 255 * (y % 2))),
        ("narrow_vertical", "L", (1, 33),
         lambda x, y, w, h: 255 * y // max(1, h - 1)),
        ("narrow_horizontal", "L", (33, 1),
         lambda x, y, w, h: 255 * x // max(1, w - 1)),
    ]
    for name, mode, size, pixel in patterns:
        width, height = min(size[0], max_side), min(size[1], max_side)
        image = Image.new(mode, (width, height))
        image.putdata([pixel(x, y, width, height) for y in range(height) for x in range(width)])
        yield name, image


def visual_variants(image: Image.Image, complex_suite: bool):
    yield "original", image
    if complex_suite:
        # Kernel supports L/RGB/RGBA; converting LA preserves its alpha coverage.
        source = image.convert("RGBA") if image.mode == "LA" else image
        for name, blur in (
            ("gaussian_0.8", ImageFilter.GaussianBlur(0.8)),
            ("gaussian_3", ImageFilter.GaussianBlur(3)),
            ("box_2", ImageFilter.BoxBlur(2)),
            ("motion_horizontal_5", ImageFilter.Kernel((5, 5), [0]*10 + [1]*5 + [0]*10, scale=5)),
        ):
            yield name, source.filter(blur)


def encoded_variants(image: Image.Image, complex_suite: bool):
    variants = [(fmt, {}) for fmt in ("PNG", "BMP", "TGA", "QOI", "GIF")]
    if complex_suite:
        variants += [("TGA", {"compression": "tga_rle"}), ("GIF", {"interlace": False})]
    for progressive in ((False, True) if complex_suite else (False,)):
        variants += [("JPEG", {"quality": 90, "subsampling": sampling, "progressive": progressive})
                     for sampling in (0, 1, 2)]
    # Convert once per mode rather than once per encoding variant.
    modes = {image.mode: image}
    for fmt, options in variants:
        if fmt in ("BMP", "GIF"):
            mode = "RGB"
        elif fmt == "JPEG":
            mode = "L" if image.mode in ("L", "LA") else "RGB"
        elif fmt == "QOI":
            mode = "RGBA"
        else:
            mode = image.mode
        if mode not in modes:
            modes[mode] = image.convert(mode)
        output = BytesIO()
        modes[mode].save(output, format=fmt, **options)
        yield fmt, options, output.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--max-side", type=int, default=128)
    parser.add_argument("--suite", choices=("basic", "complex"), default="complex")
    parser.add_argument("--timeout", type=float, default=30,
                        help="Per-image decoder timeout in seconds (default: 30)")
    args = parser.parse_args()
    if args.max_side < 1 or args.max_side > 4096:
        parser.error("--max-side must be between 1 and 4096")
    if args.corpus and not args.corpus.is_dir():
        parser.error("--corpus must be an existing directory")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    build = ROOT / "_build"
    build.mkdir(exist_ok=True)
    results = []
    failures_dir = build / "decoder-reference-failures"
    started = time.monotonic()

    def compare(worker, name, encoded, kind, visual="original", options=None):
        digest = hashlib.sha256(encoded).hexdigest()
        row = {"source": name, "kind": kind, "visual": visual, "encoding": options or {},
               "sha256": digest, "encoded_bytes": len(encoded)}
        try:
            with Image.open(BytesIO(encoded)) as input_image:
                fmt = input_image.format
                row["progressive"] = bool(input_image.info.get("progressive", False))
            reference = reference_rgba(encoded)
            row.update(format=fmt, width=reference.width, height=reference.height)
            meta, actual = worker.decode(encoded)
            expected = reference.tobytes()
            valid_shape = (meta.get("width") == reference.width and meta.get("height") == reference.height
                           and len(actual) == len(expected))
            maximum, total_error = 0, 0
            for a, b in zip(actual, expected):
                difference = abs(a - b)
                maximum = max(maximum, difference)
                total_error += difference
            row.update(ok=valid_shape and maximum <= (3 if fmt == "JPEG" else 0),
                       valid_shape=valid_shape, max_error=maximum,
                       mean_error=total_error / max(1, len(expected)), decode_ms=meta["decode_ms"])
        except (OSError, ValueError, RuntimeError, Image.DecompressionBombError) as error:
            row.update(ok=False, error=str(error))
        if not row["ok"]:
            failures_dir.mkdir(exist_ok=True)
            case_path = failures_dir / (digest + ".image")
            case_path.write_bytes(encoded)
            row["input_path"] = str(case_path.relative_to(ROOT))
        results.append(row)

    with tempfile.TemporaryDirectory(prefix="decoder-reference-", dir=build) as temporary:
        work = Path(temporary)
        worker = DecoderWorker(build_harness(work), work, args.timeout)
        complex_suite = args.suite == "complex"

        def derived(name, image):
            for visual, candidate in visual_variants(image, complex_suite):
                for _, options, encoded in encoded_variants(candidate, complex_suite):
                    compare(worker, name, encoded, "generated", visual, options)

        try:
            # Preserve original dimensions and encoding. Derive one source at a
            # time, keeping neither the whole corpus nor all encodings in memory.
            for original in original_images(args.corpus):
                name, encoded, read_error = original
                if read_error is not None:
                    results.append({"source": name, "kind": "original", "ok": False, "error": read_error})
                    continue
                compare(worker, name, encoded, "original")
                for source_name, image in source_images([original], args.max_side, include_patterns=False):
                    derived(source_name, image)
            for name, image in source_images([], args.max_side):
                derived(name, image)
            if complex_suite:
                for name, image in complex_patterns(args.max_side):
                    derived(name, image)
        finally:
            worker.close()
    report = build / "decoder-reference-results.json"
    report.write_text(json.dumps({"pillow": pillow_version, "suite": args.suite,
                                  "max_side": args.max_side, "timeout_seconds": args.timeout,
                                  "elapsed_seconds": time.monotonic() - started,
                                  "cases": results, "passed": sum(r["ok"] for r in results),
                                  "total": len(results)}, indent=2), encoding="utf-8")
    failures = [row for row in results if not row["ok"]]
    for row in failures:
        print(json.dumps(row))
    print(f"Independent reference: {len(results)-len(failures)}/{len(results)} passed; {report}")
    if not results or failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
