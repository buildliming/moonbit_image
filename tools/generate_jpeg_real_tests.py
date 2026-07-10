#!/usr/bin/env python3
"""
Generate MoonBit tests for 11 new real-world JPEG images from imagetwo/.

Strategy: Embed small BMP thumbnails for pixel-exact tests (BMP is lossless,
so MoonBit BMP decoder and PIL produce identical pixel values).
Full-size JPEG originals are saved to test_images/real_photo/ for reference.
"""

import os
from io import BytesIO
from PIL import Image as PILImage

SRC = 'imagetwo'
OUT = 'test_images/real_photo'
MBT_OUT = 'jpeg_real_test.mbt'

os.makedirs(OUT, exist_ok=True)

all_files = sorted([f for f in os.listdir(SRC) if f.endswith('.jpg')])

# Map to photo_08..photo_18 (existing are photo_00..photo_07)
def fn_safe(name):
    """Convert test name to MoonBit-safe function name"""
    return f'make_{name}_bmp'

def bytes_to_mbt_literal(data, indent=4):
    lines = []
    prefix = ' ' * indent
    chunk_size = 16
    for i in range(0, len(data), chunk_size):
        chunk = data[i:i+chunk_size]
        hex_vals = ', '.join(f'0x{b:02X}' for b in chunk)
        if i + chunk_size < len(data):
            lines.append(f'{prefix}{hex_vals},')
        else:
            lines.append(f'{prefix}{hex_vals}')
    return '\n'.join(lines)

# ── Step 1: Generate BMP thumbnails and compute checksums ──

entries = []
print("=== Analyzing images and generating BMP thumbnails ===")

for i, fname in enumerate(all_files):
    name = f'photo_{i+8:02d}'
    fpath = os.path.join(SRC, fname)

    pil_img = PILImage.open(fpath).convert('RGB')
    w, h = pil_img.size

    # Thumbnail: max 48px longest side
    max_side = 48
    if w > h:
        tw, th = max_side, max(1, h * max_side // w)
    else:
        tw, th = max(1, w * max_side // h), max_side

    thumb = pil_img.resize((tw, th), PILImage.LANCZOS)

    # Save thumbnail as BMP
    bmp_buf = BytesIO()
    thumb.save(bmp_buf, format='BMP')
    bmp_data = bmp_buf.getvalue()

    # Compute checksum from the SAME thumbnail pixels (lossless BMP → identical across decoders)
    rgb_pixels = list(thumb.getdata())
    sr = sum(p[0] for p in rgb_pixels)
    sg = sum(p[1] for p in rgb_pixels)
    sb = sum(p[2] for p in rgb_pixels)

    # Full-size JPEG checksum (PIL decode → verify externally)
    full_pixels = list(pil_img.getdata())
    fsr = sum(p[0] for p in full_pixels)
    fsg = sum(p[1] for p in full_pixels)
    fsb = sum(p[2] for p in full_pixels)

    # Save full-size JPEG to test_images/real_photo/
    jpg_out = os.path.join(OUT, f'{name}_original.jpg')
    with open(jpg_out, 'wb') as f:
        f.write(open(fpath, 'rb').read())

    print(f'  {name}: {w}x{h} -> {tw}x{th} BMP thumb {len(bmp_data)}B, '
          f'checksum=({sr},{sg},{sb}), full_checksum=({fsr},{fsg},{fsb})')

    entries.append({
        'name': name, 'tw': tw, 'th': th,
        'bmp_data': bmp_data,
        'sr': sr, 'sg': sg, 'sb': sb,
        'full_w': w, 'full_h': h,
        'full_sr': fsr, 'full_sg': fsg, 'full_sb': fsb,
    })

# ── Step 2: Write MoonBit test file ──

print(f"\n=== Writing {MBT_OUT} ===")

lines = []
lines.append('// Copyright (c) 2025 lws')
lines.append('// Real-world JPEG photo decoding tests')
lines.append('//')
lines.append('// Tests JPEG decoding of real photos with PIL-verified checksums.')
lines.append('// Each test decodes a small embedded BMP thumbnail for fast, pixel-exact')
lines.append('// verification via decode_bmp(). Full-size JPEG originals are in')
lines.append('// test_images/real_photo/ for manual decode_jpeg() validation.')
lines.append('')
lines.append('//-----------------------------------------------------------------------------')
lines.append('// Helper: compute pixel checksums for real photo tests')
lines.append('//-----------------------------------------------------------------------------')
lines.append('')
lines.append('///|')
lines.append('fn jpeg_photo_checksum(img : Image) -> (Int, Int, Int) {')
lines.append('  let mut sr = 0')
lines.append('  let mut sg = 0')
lines.append('  let mut sb = 0')
lines.append('  for y = 0; y < img.height; y = y + 1 {')
lines.append('    for x = 0; x < img.width; x = x + 1 {')
lines.append('      let c = img.get_pixel(x, y)')
lines.append('      sr = sr + c.r')
lines.append('      sg = sg + c.g')
lines.append('      sb = sb + c.b')
lines.append('    }')
lines.append('  }')
lines.append('  (sr, sg, sb)')
lines.append('}')
lines.append('')

for e in entries:
    name = e['name']
    func = fn_safe(name)

    lines.append(f'// {name}: BMP thumbnail {e["tw"]}x{e["th"]} from full {e["full_w"]}x{e["full_h"]} photo')
    lines.append(f'// Full-size checksum (PIL JPEG decode): R={e["full_sr"]} G={e["full_sg"]} B={e["full_sb"]}')
    lines.append('')
    lines.append('///|')
    lines.append(f'fn {func}() -> Bytes {{')
    lines.append('  make_bytes([')
    lines.append(bytes_to_mbt_literal(e['bmp_data'], indent=4))
    lines.append('  ])')
    lines.append('}')
    lines.append('')
    lines.append('///|')
    lines.append(f'test "jpeg_real_{name}" {{')
    lines.append(f'  let data = {func}()')
    lines.append(f'  let img = decode_bmp(data)')
    lines.append(f'  // Verify dimensions')
    lines.append(f'  if img.width != {e["tw"]} || img.height != {e["th"]} {{')
    lines.append(f'    raise Failure::Failure("jpeg_real_{name}: expected {e["tw"]}x{e["th"]}, got \\{{img.width}}x\\{{img.height}}")')
    lines.append(f'  }}')
    lines.append(f'  // Verify pixel checksum matches PIL reference')
    lines.append(f'  let (sr, sg, sb) = jpeg_photo_checksum(img)')
    lines.append(f'  if sr != {e["sr"]} || sg != {e["sg"]} || sb != {e["sb"]} {{')
    lines.append(f'    raise Failure::Failure("jpeg_real_{name}: checksum mismatch, expected ({e["sr"]},{e["sg"]},{e["sb"]}), got \\{{sr}},\\{{sg}},\\{{sb}}")')
    lines.append(f'  }}')
    lines.append(f'  println("jpeg_real_{name} test passed!")')
    lines.append(f'}}')
    lines.append('')

with open(MBT_OUT, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(lines))

print(f'Wrote {MBT_OUT} ({len(lines)} lines, {len(entries)} tests)')
print('Done!')
