# Changelog

## 0.2.1 — 2026-10-28

- Restore all embedded tests, image fixtures, independent pixel expectations and
  generation/reference scripts to the Mooncakes package for reproduction.
- Store the largest fixtures in Base64 without changing their bytes or assertions,
  keeping the full package below the previously rejected upload size. Decoding the
  fixtures uses MoonBit's standard library and adds no library runtime dependency.
- Make photo generation and reference comparison read both fixture representations;
  document reproduction directly from the published package without original photos.

## 0.2.0 — 2026-10-28

- Decode 8-bit progressive JPEG (SOF2), including spectral selection, DC/AC
  refinement, subsampling and restart markers; validate scan order and bound
  coefficient storage. Use compact canonical Huffman tables.
- Reduce temporary allocation across all six decoders: transfer completed
  BMP/QOI/TGA buffers, reuse PNG scanlines and avoid redundant GIF frame copies.
  Bound cumulative PNG IDAT data and progressive JPEG working buffers.
- Expand the independent six-format comparison to 1311 real-photo, blur,
  gradient, alpha and edge-dimension cases, including 300 progressive JPEGs.
  Reuse the decoder process, enforce per-case timeouts and clean temporary files.
- Preserve the public API; add regenerable progressive and resource regressions.

Validation: 651 tests on both wasm-gc and JavaScript, 9 Python oracle/worker
tests, and 1311 independent reference comparisons. Lossless pixels match
exactly; JPEG permits at most three levels of error per channel. Local native
execution was unavailable because the Windows C toolchain could not start;
the existing Linux native CI job remains enabled.

## 0.1.5 — 2026-10-25

- Harden BMP, QOI, TGA, GIF and baseline JPEG decoding: validate headers,
  compressed streams, palettes, frame bounds and truncated input.
- Correct PNG sample decoding, transparency, Adam7 passes and DEFLATE block
  handling, including independent checksum and stream validation.
- Bound decoder allocations and retained GIF animation frames; malformed or
  unsupported input raises `Failure`.
- Add independent pixel regression fixtures and a reusable Pillow comparison
  tool. Validate wasm-gc, JavaScript and native targets in CI.
- Document supported variants, alpha behavior and resource limits. Existing
  public decoding APIs are preserved.

Validation: 603 MoonBit tests per target and 131 independent reference cases.
Lossless pixels must match exactly; JPEG permits at most three levels of error
per channel. See README.md for supported variants and reproducible commands.
