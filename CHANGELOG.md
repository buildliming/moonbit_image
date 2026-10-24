# Changelog

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
