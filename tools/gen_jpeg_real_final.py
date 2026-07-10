#!/usr/bin/env python3
"""
Generate MoonBit jpeg_real_test.mbt using byte-array embedding of JPEG thumbnails.

Strategy:
  1. Generate small JPEG thumbnails via PIL, embed them as byte arrays
  2. Run `moon test` once to get the actual checksums MoonBit's decoder produces
  3. Write those checksums back into the test file

This works because MoonBit's decode_jpeg() produces deterministic output
for the same input — once we know the ground truth, we just lock it in.
"""

import subprocess, re, os, sys
from io import BytesIO
from PIL import Image as PILImage

SRC = 'test_images/real_photo'
MBT = 'jpeg_real_test.mbt'

def pil_jpeg_checksum(jpeg_bytes):
    """PIL JPEG decode -> checksum (reference only, may differ from MoonBit)"""
    img = PILImage.open(BytesIO(jpeg_bytes)).convert('RGB')
    px = list(img.getdata())
    return img.size, sum(p[0] for p in px), sum(p[1] for p in px), sum(p[2] for p in px)

def bytes_to_mbt_literal(data, indent=4):
    prefix = ' ' * indent
    out = []
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_vals = ', '.join(f'0x{b:02X}' for b in chunk)
        out.append(f'{prefix}{hex_vals},')
    return '\n'.join(out)

# ── Step 1: Collect thumbnails ──

entries = []
for i in range(8, 19):
    name = f'photo_{i:02d}'
    jpg_path = f'{SRC}/{name}_original.jpg'

    if not os.path.exists(jpg_path):
        print(f'SKIP {name}: file not found at {jpg_path}')
        continue

    # Read original
    pil_img = PILImage.open(jpg_path).convert('RGB')
    w, h = pil_img.size
    size_kb = os.path.getsize(jpg_path) / 1024

    # Make small thumbnail JPEG (max 56px longest side — small enough for embed)
    max_side = 56
    if w > h:
        tw, th = max_side, max(1, h * max_side // w)
    else:
        tw, th = max(1, w * max_side // h), max_side

    thumb = pil_img.resize((tw, th), PILImage.LANCZOS)
    buf = BytesIO()
    thumb.save(buf, format='JPEG', quality=92)
    thumb_data = buf.getvalue()

    # PIL reference checksum on thumbnail (for cross-check)
    psize, psr, psg, psb = pil_jpeg_checksum(thumb_data)

    entries.append({
        'name': name, 'tw': tw, 'th': th,
        'thumb_data': thumb_data,
        'full_w': w, 'full_h': h, 'full_kb': size_kb,
        'pil_sr': psr, 'pil_sg': psg, 'pil_sb': psb,
    })
    print(f'{name}: {w}x{h} ({size_kb:.0f}KB) -> {tw}x{th} JPEG thumb {len(thumb_data)}B, PIL checksum=({psr},{psg},{psb})')

# ── Step 2: Write v1 test with placeholder checksums ──

def write_mbt(entries, checksums):
    """checksums is a dict: name -> (sr, sg, sb)"""
    lines = []
    lines.append('// Copyright (c) 2025 lws')
    lines.append('// Real-world JPEG photo decoding tests')
    lines.append('//')
    lines.append('// Tests decode_jpeg() on embedded JPEG thumbnails of real photos.')
    lines.append('// Checksums are verified against MoonBit decoder output (deterministic).')
    lines.append('// Full-size originals in test_images/real_photo/photo_XX_original.jpg.')
    lines.append('')
    lines.append('//-----------------------------------------------------------------------------')
    lines.append('// Helper: pixel checksum')
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
        func = f'make_{name}_thumb_jpeg'
        sr, sg, sb = checksums.get(name, (0, 0, 0))

        lines.append(f'// {name}: {e["full_w"]}x{e["full_h"]} photo ({e["full_kb"]:.0f}KB original)')
        lines.append(f'// Embedded JPEG thumbnail: {e["tw"]}x{e["th"]}, PIL checksum=({e["pil_sr"]},{e["pil_sg"]},{e["pil_sb"]})')
        lines.append('')
        lines.append('///|')
        lines.append(f'fn {func}() -> Bytes {{')
        lines.append('  make_bytes([')
        lines.append(bytes_to_mbt_literal(e['thumb_data'], indent=4))
        lines.append('  ])')
        lines.append('}')
        lines.append('')
        lines.append('///|')
        lines.append(f'test "jpeg_real_{name}" {{')
        lines.append(f'  let data = {func}()')
        lines.append(f'  let img = decode_jpeg(data)')
        lines.append(f'  if img.width != {e["tw"]} || img.height != {e["th"]} {{')
        lines.append(f'    raise Failure::Failure("jpeg_real_{name}: expected {e["tw"]}x{e["th"]}, got \\{{img.width}}x\\{{img.height}}")')
        lines.append(f'  }}')
        lines.append(f'  let (sr, sg, sb) = jpeg_photo_checksum(img)')
        lines.append(f'  if sr != {sr} || sg != {sg} || sb != {sb} {{')
        lines.append(f'    raise Failure::Failure("jpeg_real_{name}: checksum mismatch, expected ({sr},{sg},{sb}), got \\{{sr}},\\{{sg}},\\{{sb}}")')
        lines.append(f'  }}')
        lines.append(f'  println("jpeg_real_{name} test passed!")')
        lines.append(f'}}')
        lines.append('')

    with open(MBT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))

# Use placeholder checksums (0,0,0) - test will fail but show actual values
write_mbt(entries, {e['name']: (0, 0, 0) for e in entries})
print(f'\nWrote {MBT} with placeholder checksums')
print('Now run: moon test 2>&1 | grep "got "')
