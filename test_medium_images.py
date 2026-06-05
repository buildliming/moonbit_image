"""
Generate medium-sized test images (512x512 and 64x64) for MoonBit decoder testing.
Also verifies them with PIL as reference.
Each image uses a predictable pattern: R=(x*7)%256, G=(y*13)%256, B=((x+y)*11)%256
"""
import struct
import zlib
import os
import hashlib

OUT_DIR = "d:/moonbit-image/test_images"
os.makedirs(OUT_DIR, exist_ok=True)

def pixel_r(x, y):
    return (x * 7) % 256

def pixel_g(x, y):
    return (y * 13) % 256

def pixel_b(x, y):
    return ((x + y) * 11) % 256

def pixel_a(x, y):
    return 255


# ============================================================
# BMP 24-bit BGR (bottom-up)
# ============================================================
def make_bmp(width, height):
    row_size = ((width * 3 + 3) // 4) * 4
    image_size = row_size * height
    file_size = 14 + 40 + image_size
    data_offset = 14 + 40

    buf = bytearray()
    # File header
    buf += b'BM'
    buf += struct.pack('<I', file_size)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<I', data_offset)
    # DIB header
    buf += struct.pack('<I', 40)
    buf += struct.pack('<i', width)
    buf += struct.pack('<i', height)  # bottom-up
    buf += struct.pack('<H', 1)
    buf += struct.pack('<H', 24)
    buf += struct.pack('<I', 0)       # BI_RGB
    buf += struct.pack('<I', image_size)
    buf += struct.pack('<i', 2835)
    buf += struct.pack('<i', 2835)
    buf += struct.pack('<I', 0)
    buf += struct.pack('<I', 0)

    # Pixel data: bottom row first
    for y in range(height - 1, -1, -1):
        for x in range(width):
            buf += bytes([pixel_b(x, y), pixel_g(x, y), pixel_r(x, y)])
        # Padding
        padding_needed = row_size - width * 3
        buf += bytes([0] * padding_needed)

    return bytes(buf)


# ============================================================
# PNG 24-bit RGB, filter=0 (None)
# ============================================================
def make_png(width, height, color_type=2):
    """color_type: 0=gray, 2=RGB, 4=GrayA, 6=RGBA"""
    channels_map = {0: 1, 2: 3, 4: 2, 6: 4}
    channels = channels_map[color_type]
    bpp = channels

    # Build raw filtered scanlines
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: None
        for x in range(width):
            raw.append(pixel_r(x, y))
            if channels >= 3:
                raw.append(pixel_g(x, y))
                raw.append(pixel_b(x, y))
            if channels == 4:
                raw.append(pixel_a(x, y))
            if channels == 2:  # GrayA
                raw.append(pixel_a(x, y))

    compressed = zlib.compress(bytes(raw))

    def make_chunk(chunk_type, data):
        c = bytearray()
        c += struct.pack('>I', len(data))
        c += chunk_type
        c += data
        crc = zlib.crc32(bytes(c[4:])) & 0xFFFFFFFF
        c += struct.pack('>I', crc)
        return bytes(c)

    buf = bytearray()
    buf += bytes([137, 80, 78, 71, 13, 10, 26, 10])

    ihdr = bytearray()
    ihdr += struct.pack('>I', width)
    ihdr += struct.pack('>I', height)
    ihdr += struct.pack('<B', 8)        # bit depth
    ihdr += struct.pack('<B', color_type)
    ihdr += struct.pack('<B', 0)        # compression
    ihdr += struct.pack('<B', 0)        # filter
    ihdr += struct.pack('<B', 0)        # interlace
    buf += make_chunk(b'IHDR', bytes(ihdr))
    buf += make_chunk(b'IDAT', compressed)
    buf += make_chunk(b'IEND', b'')
    return bytes(buf)


# ============================================================
# TGA 24-bit uncompressed, top-left origin
# ============================================================
def make_tga(width, height):
    buf = bytearray()
    buf += struct.pack('<B', 0)    # ID length
    buf += struct.pack('<B', 0)    # color map type
    buf += struct.pack('<B', 2)    # image type (uncompressed true-color)
    buf += struct.pack('<H', 0)    # first entry index
    buf += struct.pack('<H', 0)    # color map length
    buf += struct.pack('<B', 0)    # color map entry size
    buf += struct.pack('<H', 0)    # x-origin
    buf += struct.pack('<H', 0)    # y-origin
    buf += struct.pack('<H', width)
    buf += struct.pack('<H', height)
    buf += struct.pack('<B', 24)   # pixel depth
    buf += struct.pack('<B', 0x20) # top-left, 0 alpha bits

    for y in range(height):
        for x in range(width):
            buf += bytes([pixel_b(x, y), pixel_g(x, y), pixel_r(x, y)])

    return bytes(buf)


# ============================================================
# QOI RGB
# ============================================================
def make_qoi(width, height):
    """Generate QOI image using QOI_OP_RGB for each pixel.
    Not the most efficient encoding, but correct."""
    buf = bytearray()
    buf += b'qoif'
    buf += struct.pack('>I', width)
    buf += struct.pack('>I', height)
    buf += struct.pack('<B', 3)    # channels = RGB
    buf += struct.pack('<B', 0)    # colorspace = sRGB

    prev_r, prev_g, prev_b = 0, 0, 0
    for y in range(height):
        for x in range(width):
            r, g, b = pixel_r(x, y), pixel_g(x, y), pixel_b(x, y)
            dr = (r - prev_r) & 0xFF
            dg = (g - prev_g) & 0xFF
            db = (b - prev_b) & 0xFF
            # Try to use QOI_OP_DIFF or QOI_OP_LUMA for efficiency,
            # but for correctness just use QOI_OP_RGB
            buf += bytes([0xFE, r, g, b])
            prev_r, prev_g, prev_b = r, g, b

    # End marker
    buf += bytes([0, 0, 0, 0, 0, 0, 0, 1])
    return bytes(buf)


# ============================================================
# Generate & save images
# ============================================================
sizes = [64, 512]
formats = []

for size in sizes:
    tag = f"{size}x{size}"
    images = {
        f"bmp_{tag}.bmp": make_bmp(size, size),
        f"png_{tag}.png": make_png(size, size, 2),      # RGB
        f"png_rgba_{tag}.png": make_png(size, size, 6),  # RGBA
        f"tga_{tag}.tga": make_tga(size, size),
        f"qoi_{tag}.qoi": make_qoi(size, size),
    }
    for name, data in images.items():
        path = os.path.join(OUT_DIR, name)
        with open(path, "wb") as f:
            f.write(data)
        size_kb = len(data) / 1024
        md5 = hashlib.md5(data).hexdigest()
        print(f"  {name:30s} {len(data):>10,} bytes ({size_kb:>8.2f} KB)  MD5={md5}")
        if size == 512:
            formats.append((name, path, data))


# ============================================================
# Verify with PIL
# ============================================================
print("\n" + "=" * 70)
print("PIL Reference Verification (512x512 images)")
print("=" * 70)

from PIL import Image

for name, path, data in formats:
    try:
        img = Image.open(path)
        w, h = img.size
        img_rgba = img.convert("RGBA")

        errors = 0
        max_errors = 10
        for y in range(h):
            for x in range(w):
                expected_r = pixel_r(x, y)
                expected_g = pixel_g(x, y)
                expected_b = pixel_b(x, y)
                pr, pg, pb, pa = img_rgba.getpixel((x, y))
                if pr != expected_r or pg != expected_g or pb != expected_b:
                    if errors < max_errors:
                        print(f"  MISMATCH at ({x},{y}): expected=({expected_r},{expected_g},{expected_b}), got=({pr},{pg},{pb})")
                    errors += 1
            if errors >= max_errors:
                break

        pixel_count = w * h
        if errors == 0:
            print(f"  {name:30s} {w}x{h} - ALL {pixel_count:,} pixels CORRECT ✅")
        else:
            print(f"  {name:30s} {w}x{h} - {errors} PIXEL ERRORS ❌")
    except Exception as e:
        print(f"  {name:30s} ERROR: {e}")


# ============================================================
# Print checksums for MoonBit verification
# ============================================================
print("\n" + "=" * 70)
print("Checksums for MoonBit decoder verification (pixel checksum = sum of all R+G+B)")
print("=" * 70)

for name, path, data in formats:
    img = Image.open(path)
    img_rgba = img.convert("RGBA")
    w, h = img.size

    total_r, total_g, total_b = 0, 0, 0
    for y in range(h):
        for x in range(w):
            pr, pg, pb, _ = img_rgba.getpixel((x, y))
            total_r += pr
            total_g += pg
            total_b += pb

    print(f"  {name:30s} sum_r={total_r:>12,}  sum_g={total_g:>12,}  sum_b={total_b:>12,}")

print("\nAll test images generated in:", OUT_DIR)
