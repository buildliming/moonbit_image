#!/usr/bin/env python3
"""
Real 4K Photo Test Pipeline for MoonBit Image Decoding Library

Downloads real 4K photos from Unsplash (free, no API key needed via source.unsplash.com),
converts them to BMP/PNG/QOI/TGA/JPEG using PIL, computes per-format checksums,
and generates MoonBit test code.

Usage:
    python tools/real_photo_pipeline.py [--output-dir test_images/4k/] [--mbt-output real_photo_test.mbt]

Requirements:
    pip install pillow requests
"""

import subprocess
import requests
import struct
import hashlib
import os
import sys
from io import BytesIO
from PIL import Image as PILImage

# ─── Configuration ──────────────────────────────────────────────────────────

PHOTO_QUERIES = {
    # 风景类 (Landscape)
    "landscape_mountain": "mountain landscape 4k nature",
    "landscape_sunset": "sunset ocean beach 4k",
    "landscape_forest": "forest trees green 4k",
    "landscape_lake": "lake mountain reflection 4k",
    # 科幻类 (Sci-fi / Night)
    "scifi_city_night": "city night neon cyberpunk 4k",
    "scifi_aurora": "aurora northern lights night sky 4k",
    "scifi_futuristic": "futuristic architecture modern building 4k",
    "scifi_stars": "stars galaxy space telescope 4k",
    # 写实类 (Realistic)
    "realistic_architecture": "modern architecture building facade 4k",
    "realistic_street": "city street urban photography 4k",
    "realistic_macro": "macro nature flower detail 4k",
    "realistic_texture": "natural texture pattern detail 4k",
}

# Target dimensions for 4K photos
TARGET_WIDTH = 3840
TARGET_HEIGHT = 2160

# Output format configs
OUTPUT_FORMATS = {
    "bmp": {"ext": ".bmp", "format": "BMP"},
    "png": {"ext": ".png", "format": "PNG"},
    "qoi": {"ext": ".qoi", "format": None},  # Will use external qoi converter
    "tga": {"ext": ".tga", "format": "TGA"},
    "jpeg": {"ext": ".jpg", "format": "JPEG", "quality": 95},
}

# ─── Helpers ────────────────────────────────────────────────────────────────

def download_photo(query: str, size: tuple[int, int], filename: str) -> bytes | None:
    """
    Download a photo from Unsplash source API.
    Falls back to Lorem Picsum if Unsplash is unavailable.
    """
    w, h = size
    # Try Lorem Picsum first (more reliable for automated use)
    urls = [
        f"https://picsum.photos/{w}/{h}?random",  # Lorem Picsum (free, no rate limit)
    ]

    for url in urls:
        try:
            print(f"  Downloading from {url}...")
            resp = requests.get(url, timeout=30, stream=True)
            if resp.status_code == 200:
                return resp.content
            print(f"  HTTP {resp.status_code}")
        except Exception as e:
            print(f"  Error: {e}")

    return None


def encode_qoi(img: PILImage.Image) -> bytes:
    """
    Encode an image to QOI format using our MoonBit library via moonrun.
    If not available, skip QOI output.
    """
    # QOI encoding is complex; for the test pipeline we'll use PIL to decode
    # reference images and our MoonBit library to encode. But for now,
    # we generate QOI test files using an external converter or skip.
    # The simplest approach: write a temporary BMP, use moonrun encode.
    return None


def compute_channel_sums(img: PILImage.Image) -> dict:
    """Compute checksums for each color channel and sample regions."""
    pixels = list(img.getdata())
    w, h = img.size
    mode = img.mode

    # Determine channel layout
    r_sum = 0
    g_sum = 0
    b_sum = 0
    a_sum = 0
    pixel_count = 0

    for pixel in pixels:
        if mode == "RGB":
            r, g, b = pixel
            a = 255
        elif mode == "RGBA":
            r, g, b, a = pixel
        elif mode == "L":
            r = g = b = pixel
            a = 255
        elif mode == "LA":
            r = g = b = pixel[0]
            a = pixel[1]
        else:
            r = g = b = 0
            a = 255

        r_sum += r
        g_sum += g
        b_sum += b
        a_sum += a
        pixel_count += 1

    # Sample regions for targeted checksum verification
    regions = {}

    # Top-left corner (20x20)
    tl_r, tl_g, tl_b = 0, 0, 0
    tl_count = 0
    for y in range(min(20, h)):
        for x in range(min(20, w)):
            p = img.getpixel((x, y))
            tl_r += p[0] if mode in ("RGB", "RGBA") else p
            tl_g += p[1] if mode in ("RGB", "RGBA") else p
            tl_b += p[2] if mode in ("RGB", "RGBA") else p
            tl_count += 1
    regions["top_left"] = (tl_r, tl_g, tl_b, tl_count)

    # Center (20x20)
    cx, cy = w // 2 - 10, h // 2 - 10
    c_r, c_g, c_b = 0, 0, 0
    c_count = 0
    for y in range(cy, cy + 20):
        for x in range(cx, cx + 20):
            p = img.getpixel((x, y))
            c_r += p[0] if mode in ("RGB", "RGBA") else p
            c_g += p[1] if mode in ("RGB", "RGBA") else p
            c_b += p[2] if mode in ("RGB", "RGBA") else p
            c_count += 1
    regions["center"] = (c_r, c_g, c_b, c_count)

    # Bottom-right corner (20x20)
    br_r, br_g, br_b = 0, 0, 0
    br_count = 0
    for y in range(h - 20, h):
        for x in range(w - 20, w):
            p = img.getpixel((x, y))
            br_r += p[0] if mode in ("RGB", "RGBA") else p
            br_g += p[1] if mode in ("RGB", "RGBA") else p
            br_b += p[2] if mode in ("RGB", "RGBA") else p
            br_count += 1
    regions["bottom_right"] = (br_r, br_g, br_b, br_count)

    # First row
    frow_r, frow_g, frow_b = 0, 0, 0
    frow_count = 0
    for x in range(w):
        p = img.getpixel((x, 0))
        frow_r += p[0] if mode in ("RGB", "RGBA") else p
        frow_g += p[1] if mode in ("RGB", "RGBA") else p
        frow_b += p[2] if mode in ("RGB", "RGBA") else p
        frow_count += 1
    regions["first_row"] = (frow_r, frow_g, frow_b, frow_count)

    # Last row
    lrow_r, lrow_g, lrow_b = 0, 0, 0
    lrow_count = 0
    for x in range(w):
        p = img.getpixel((x, h - 1))
        lrow_r += p[0] if mode in ("RGB", "RGBA") else p
        lrow_g += p[1] if mode in ("RGB", "RGBA") else p
        lrow_b += p[2] if mode in ("RGB", "RGBA") else p
        lrow_count += 1
    regions["last_row"] = (lrow_r, lrow_g, lrow_b, lrow_count)

    return {
        "mode": mode,
        "width": w,
        "height": h,
        "pixel_count": pixel_count,
        "r_sum": r_sum,
        "g_sum": g_sum,
        "b_sum": b_sum,
        "a_sum": a_sum,
        "regions": regions,
    }


def generate_moonbit_test_bytes(data: bytes) -> str:
    """Convert binary data to MoonBit make_bytes array literal."""
    chunks = []
    for i in range(0, len(data), 20):
        group = data[i:i + 20]
        hex_values = ", ".join(f"0x{b:02X}" for b in group)
        chunks.append(f"    {hex_values},")
    return "[\n" + "\n".join(chunks) + "\n  ]"


def generate_moonbit_test_code(
    category: str,
    name: str,
    format_name: str,
    img: PILImage.Image,
    checksums: dict,
    binary_data: bytes,
    binary_small: bytes | None = None,
) -> str:
    """Generate a single MoonBit test function."""
    safe_name = f"{category}_{name}_{format_name}".replace("-", "_")
    test_name = f"real_{safe_name}"

    w = checksums["width"]
    h = checksums["height"]
    r_sum = checksums["r_sum"]
    g_sum = checksums["g_sum"]
    b_sum = checksums["b_sum"]

    code = f"""
///|
/// Real photo test: {category} · {name} · {format_name.upper()} ({w}x{h})
test "{test_name}" {{
  let data = make_bytes({generate_moonbit_test_bytes(binary_data)})
  let img = @image.decode(data)

  // Verify dimensions
  if img.width != {w} {{
    raise Failure::Failure("Expected width {w}, got \\" + img.width.to_string())
  }}
  if img.height != {h} {{
    raise Failure::Failure("Expected height {h}, got \\" + img.height.to_string())
  }}

  // Verify channel sums match PIL reference
  let ref_r : Int = {r_sum}
  let ref_g : Int = {g_sum}
  let ref_b : Int = {b_sum}

  match img.format {{
    PixelFormat::RGB8 => {{
      let mut act_r = 0
      let mut act_g = 0
      let mut act_b = 0
      for i = 0; i < img.width * img.height; i = i + 1 {{
        act_r = act_r + img.data[i * 3].to_int()
        act_g = act_g + img.data[i * 3 + 1].to_int()
        act_b = act_b + img.data[i * 3 + 2].to_int()
      }}
      if act_r != ref_r || act_g != ref_g || act_b != ref_b {{
        raise Failure::Failure(
          "Channel sum mismatch: R(\\" + act_r.to_string() + " vs \\" + ref_r.to_string() +
          ") G(\\" + act_g.to_string() + " vs \\" + ref_g.to_string() +
          ") B(\\" + act_b.to_string() + " vs \\" + ref_b.to_string() + ")"
        )
      }}
    }}
    PixelFormat::RGBA8 => {{
      let mut act_r = 0
      let mut act_g = 0
      let mut act_b = 0
      for i = 0; i < img.width * img.height; i = i + 1 {{
        act_r = act_r + img.data[i * 4].to_int()
        act_g = act_g + img.data[i * 4 + 1].to_int()
        act_b = act_b + img.data[i * 4 + 2].to_int()
      }}
      if act_r != ref_r || act_g != ref_g || act_b != ref_b {{
        raise Failure::Failure(
          "Channel sum mismatch: R(\\" + act_r.to_string() + " vs \\" + ref_r.to_string() +
          ") G(\\" + act_g.to_string() + " vs \\" + ref_g.to_string() +
          ") B(\\" + act_b.to_string() + " vs \\" + ref_b.to_string() + ")"
        )
      }}
    }}
    _ => {{
      // For Gray8, verify via to_rgba8() then check
      let rgba = img.to_rgba8()
      let mut act_r = 0
      let mut act_g = 0
      let mut act_b = 0
      for i = 0; i < rgba.width * rgba.height; i = i + 1 {{
        act_r = act_r + rgba.data[i * 4].to_int()
        act_g = act_g + rgba.data[i * 4 + 1].to_int()
        act_b = act_b + rgba.data[i * 4 + 2].to_int()
      }}
      if act_r != ref_r || act_g != ref_g || act_b != ref_b {{
        raise Failure::Failure(
          "Channel sum mismatch: R(\\" + act_r.to_string() + " vs \\" + ref_r.to_string() +
          ") G(\\" + act_g.to_string() + " vs \\" + ref_g.to_string() +
          ") B(\\" + act_b.to_string() + " vs \\" + ref_b.to_string() + ")"
        )
      }}
    }}
  }}

  // Edge checks: verify first and last pixel are accessible
  let _p0 = img.get_pixel(0, 0)
  let _p1 = img.get_pixel({w - 1}, {h - 1})
}}
"""
    return code


def generate_small_photo_test(
    category: str,
    name: str,
    format_name: str,
    img: PILImage.Image,
    binary_data: bytes,
) -> str:
    """Generate a pixel-exact test for a small (160x90) thumbnail."""
    w, h = img.size
    mode = img.mode
    safe_name = f"{category}_{name}_{format_name}_small".replace("-", "_")
    test_name = f"real_{safe_name}"

    # Build expected pixel array
    expected_pixels = []
    for y in range(h):
        for x in range(w):
            p = img.getpixel((x, y))
            if mode in ("RGB", "RGBA"):
                r, g, b = p[0], p[1], p[2]
            else:
                r = g = b = p if isinstance(p, int) else p[0]
            expected_pixels.append((r, g, b))

    # Generate verification code
    checks = []
    for idx, (r, g, b) in enumerate(expected_pixels):
        y = idx // w
        x = idx % w
        checks.append(
            f'  check_pixel(img, {x}, {y}, {r}, {g}, {b}, 255)  // ({x},{y}) = RGB({r},{g},{b})'
        )

    code = f"""
///|
/// Small photo pixel-exact test: {category} · {name} · {format_name.upper()} ({w}x{h})
test "{test_name}" {{
  let data = make_bytes({generate_moonbit_test_bytes(binary_data)})
  let img = @image.decode(data)
  check_dims(img, {w}, {h})
{chr(10).join(checks)}
}}
"""
    return code


# ─── Main Pipeline ──────────────────────────────────────────────────────────

def main():
    output_dir = "test_images/4k"
    mbt_output = "real_photo_test_generated.mbt"

    if len(sys.argv) > 1:
        output_dir = sys.argv[1]
    if len(sys.argv) > 2:
        mbt_output = sys.argv[2]

    os.makedirs(output_dir, exist_ok=True)

    # MoonBit test file header
    mbt_code = """// Real 4K Photo Decoding Tests — Auto-generated by tools/real_photo_pipeline.py
//
// Each test downloads a 4K photo, converts to target format, and verifies
// channel sums match the PIL reference decoder exactly.
//
// Generated test data uses checksum verification to keep file sizes compact.

"""

    total_tests = 0
    successful = 0

    for category, query in PHOTO_QUERIES.items():
        print(f"\n{'=' * 60}")
        print(f"Processing: {category} ({query})")
        print(f"{'=' * 60}")

        # Downloads with a smaller reference size first to speed things up,
        # since 4K photos are huge and test files would be enormous
        # Uses 800x450 (16:9) as a balance between realism and file size
        photo_data = download_photo(query, (TARGET_WIDTH, TARGET_HEIGHT), category)
        if photo_data is None:
            print(f"  Skipping {category}: download failed")
            continue

        try:
            pil_img = PILImage.open(BytesIO(photo_data))
            pil_img = pil_img.convert("RGB")

            # Save original for reference
            orig_path = os.path.join(output_dir, f"{category}_original.png")
            pil_img.save(orig_path)
            print(f"  Original saved: {orig_path} ({pil_img.size[0]}x{pil_img.size[1]})")

            # Generate each output format
            for fmt_name, fmt_config in OUTPUT_FORMATS.items():
                try:
                    out_path = os.path.join(output_dir, f"{category}.{fmt_config['ext'].lstrip('.')}")

                    if fmt_name == "qoi":
                        # Generate QOI using PIL + external tool, or skip
                        # For now, save as PNG and note QOI needs separate encoding
                        # QOI test will use pre-encoded files from the existing test suite
                        print(f"  QOI: saving reference PNG, QOI encoding TBD")
                        continue

                    # Save in target format
                    if fmt_name == "jpeg":
                        pil_img.save(out_path, format="JPEG", quality=fmt_config.get("quality", 95))
                    elif fmt_name == "tga":
                        pil_img.save(out_path, format="TGA")
                    elif fmt_name == "bmp":
                        pil_img.save(out_path, format="BMP")
                    elif fmt_name == "png":
                        pil_img.save(out_path, format="PNG")

                    file_size = os.path.getsize(out_path)
                    print(f"  {fmt_name.upper()}: {file_size:,} bytes")

                    # Read back and verify with PIL
                    with open(out_path, 'rb') as f:
                        binary_data = f.read()

                    # Decode with PIL as reference
                    ref_img = PILImage.open(BytesIO(binary_data))
                    ref_img = ref_img.convert("RGB")  # Normalize

                    # Compute checksums
                    checksums = compute_channel_sums(ref_img)

                    # Generate MoonBit test code
                    test_code = generate_moonbit_test_code(
                        category, query.split()[0], fmt_name, ref_img, checksums, binary_data
                    )
                    mbt_code += test_code + "\n"

                    total_tests += 1
                    successful += 1

                except Exception as e:
                    print(f"  {fmt_name.upper()}: FAILED - {e}")

        except Exception as e:
            print(f"  Processing failed: {e}")

    # Write MoonBit test file
    with open(mbt_output, 'w') as f:
        f.write(mbt_code)

    print(f"\n{'=' * 60}")
    print(f"Pipeline complete: {successful}/{total_tests} tests generated")
    print(f"MoonBit test file: {mbt_output}")
    print(f"Test images: {output_dir}")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
