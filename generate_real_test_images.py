"""
Generate real test images for comprehensive MoonBit decoder testing.
Outputs MoonBit byte array code for embedding in test files.
"""
import struct
import zlib
import os

OUT = "d:/moonbit-image/test_images"
os.makedirs(OUT, exist_ok=True)

def save_raw(name, data):
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)
    print(f"  Saved {name} ({len(data)} bytes)")

def bytes_to_mbt(name, data):
    """Convert bytes to a MoonBit byte array literal."""
    lines = []
    lines.append(f"/// Auto-generated test image: {name}")
    lines.append(f"fn make_{name.replace('.', '_')}() -> Bytes {{")
    lines.append("  make_bytes([")
    chunk_size = 16
    for i in range(0, len(data), chunk_size):
        chunk = data[i:i+chunk_size]
        hex_vals = ", ".join(f"0x{b:02X}" for b in chunk)
        if i + chunk_size < len(data):
            lines.append(f"    {hex_vals},")
        else:
            lines.append(f"    {hex_vals}")
    lines.append("  ])")
    lines.append("}")
    return "\n".join(lines)

# ================================================================
# BMP Tests: Realistic images
# ================================================================

def make_bmp_32bit_alpha(w=6, h=4):
    """6x4 BMP 32-bit BGRA with varying alpha patterns."""
    buf = bytearray()
    row_size = w * 4  # tightly packed for 32-bit
    image_size = row_size * h
    file_size = 14 + 40 + image_size
    data_offset = 14 + 40

    # File header
    buf += b'BM'
    buf += struct.pack('<I', file_size)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<I', data_offset)
    # DIB header (BITMAPINFOHEADER)
    buf += struct.pack('<I', 40)
    buf += struct.pack('<i', w)
    buf += struct.pack('<i', h)   # bottom-up
    buf += struct.pack('<H', 1)
    buf += struct.pack('<H', 32)
    buf += struct.pack('<I', 0)   # BI_RGB
    buf += struct.pack('<I', image_size)
    buf += struct.pack('<i', 2835)
    buf += struct.pack('<i', 2835)
    buf += struct.pack('<I', 0)
    buf += struct.pack('<I', 0)

    # Bottom-up rows: row 0 is bottom of image
    pixels_bottom_to_top = []
    # Bottom row (y=3): gradient of alpha 0→255
    for x in range(w):
        r = (x * 50) % 256
        g = 100
        b = (200 - x * 30) % 256
        a = min(255, x * 255 // max(1, w - 1))
        pixels_bottom_to_top.append((b, g, r, a))
    # Row y=2: solid colors
    for x in range(w):
        r = (x * 40 + 10) % 256
        g = (x * 60 + 50) % 256
        b = (x * 80 + 100) % 256
        pixels_bottom_to_top.append((b, g, r, 255))
    # Row y=1: semi-transparent red variants
    for x in range(w):
        a = min(255, 64 + x * 40)
        pixels_bottom_to_top.append((0, 0, 255, a))
    # Top row (y=0): fully transparent gradient
    for x in range(w):
        pixels_bottom_to_top.append((128, 128, 128, 0))

    for (b, g, r, a) in pixels_bottom_to_top:
        buf += bytes([b, g, r, a])

    return bytes(buf), w, h, "RGBA"

def make_bmp_8bit_indexed(w=8, h=4):
    """8x4 BMP 8-bit indexed with a 256-color gradient palette."""
    row_size = ((w * 1 + 3) // 4) * 4  # 8 bytes for w=8
    image_size = row_size * h
    palette_size = 256 * 4
    data_offset = 14 + 40 + palette_size
    file_size = data_offset + image_size

    buf = bytearray()
    buf += b'BM'
    buf += struct.pack('<I', file_size)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<I', data_offset)
    buf += struct.pack('<I', 40)
    buf += struct.pack('<i', w)
    buf += struct.pack('<i', h)
    buf += struct.pack('<H', 1)
    buf += struct.pack('<H', 8)
    buf += struct.pack('<I', 0)
    buf += struct.pack('<I', image_size)
    buf += struct.pack('<i', 2835)
    buf += struct.pack('<i', 2835)
    buf += struct.pack('<I', 256)
    buf += struct.pack('<I', 256)

    # Palette: 256 entries (BGR0), gradient from blue→green→red
    for i in range(256):
        if i < 85:
            r, g, b = i * 3, 0, 255 - i * 3
        elif i < 170:
            r, g, b = 0, (i - 85) * 3, 0
        else:
            r, g, b = (i - 170) * 3, 255 - (i - 170) * 3, 0
        buf += bytes([b, g, r, 0])

    # Pixel data (bottom-up): index pattern
    for row in range(h):
        for x in range(w):
            buf += bytes([(row * w + x) % 256])
        # Padding to 4-byte boundary
        padding = row_size - w
        if padding > 0:
            buf += bytes([0] * padding)

    return bytes(buf), w, h, "RGBA"

# ================================================================
# TGA Tests: Realistic images
# ================================================================

def make_tga_rgba_rle(w=6, h=4):
    """6x4 TGA Type 10 RLE RGBA (32-bit) with repeatable patterns."""
    buf = bytearray()
    buf += struct.pack('<B', 0)   # ID length
    buf += struct.pack('<B', 0)   # color map type
    buf += struct.pack('<B', 10)  # RLE true-color
    buf += struct.pack('<H', 0)  # first entry index (2 bytes)
    buf += struct.pack('<H', 0)  # color map length (2 bytes)
    buf += struct.pack('<B', 0)  # color map entry size (1 byte)
    buf += struct.pack('<H', 0)   # x-origin
    buf += struct.pack('<H', 0)   # y-origin
    buf += struct.pack('<H', w)
    buf += struct.pack('<H', h)
    buf += struct.pack('<B', 32)  # pixel depth
    buf += struct.pack('<B', 0x20) # top-left

    # Create pixel data with vertical color bars so RLE compresses well
    # Each column is a solid color → 4-pixel RLE run per column
    for y in range(h):
        for x in range(w):
            if x < 2:
                # First 2 columns: red gradient (RLE pack: 2 pixels raw)
                buf += bytes([0, 0, 255 - x * 30, 255])
            elif x < 4:
                # Next 2 columns: green
                buf += bytes([0, 255 - (x-2)*30, 0, 200])
            else:
                # Last 2 columns: blue
                buf += bytes([255 - (x-4)*30, 0, 0, 150])

    return bytes(buf), w, h, "RGBA"

def make_tga_16bit(w=4, h=4):
    """4x4 TGA Type 2 16-bit A1R5G5B5 uncompressed, bottom-left origin."""
    buf = bytearray()
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 2)   # uncompressed true-color
    buf += struct.pack('<H', 0)  # first entry (2 bytes)
    buf += struct.pack('<H', 0)  # color map length (2 bytes)
    buf += struct.pack('<B', 0)  # color map entry size (1 byte)
    buf += struct.pack('<H', 0) * 2  # origins
    buf += struct.pack('<H', w)
    buf += struct.pack('<H', h)
    buf += struct.pack('<B', 16)
    buf += struct.pack('<B', 0x00) # bottom-left origin

    # Bottom-to-top rows
    for y in range(h):
        for x in range(w):
            r5 = x * 31 // (w - 1) if w > 1 else 31
            g5 = y * 31 // (h - 1) if h > 1 else 31
            b5 = ((x + y) * 31 // (w + h - 2)) if w + h > 2 else 15
            a1 = 1 if (x + y) % 2 == 0 else 0
            val = (a1 << 15) | (r5 << 10) | (g5 << 5) | b5
            buf += struct.pack('<H', val)

    return bytes(buf), w, h, "RGBA"

# ================================================================
# QOI Tests: Realistic images
# ================================================================

def make_qoi_diverse(w=8, h=4):
    """8x4 QOI RGBA with diverse colors exercising all chunk types."""
    buf = bytearray()
    buf += b'qoif'
    buf += struct.pack('>I', w)
    buf += struct.pack('>I', h)
    buf += struct.pack('<B', 4)   # RGBA
    buf += struct.pack('<B', 0)   # sRGB

    # Generate pixels row-by-row
    # Row 0: gradient R from 0→255 (uses DIFF chunks)
    # Row 1: gradient G from 0→255
    # Row 2: gradient B from 0→255
    # Row 3: repeating pattern (exercises RUN and INDEX chunks)

    pixels = []
    for y in range(h):
        for x in range(w):
            if y == 0:
                r, g, b, a = x * 36 % 256, 0, 0, 255
            elif y == 1:
                r, g, b, a = 0, x * 36 % 256, 0, 255
            elif y == 2:
                r, g, b, a = 0, 0, x * 36 % 256, 255
            else:
                # Repeating pattern: Red, Green, Blue, White, Red, Green, Blue, White
                c = x % 4
                if c == 0:   r, g, b, a = 255, 0, 0, 255
                elif c == 1: r, g, b, a = 0, 255, 0, 255
                elif c == 2: r, g, b, a = 0, 0, 255, 255
                else:        r, g, b, a = 255, 255, 255, 255
            pixels.append((r, g, b, a))

    # Simple encoder: all QOI_OP_RGBA for correctness (not max compression)
    for (r, g, b, a) in pixels:
        buf += bytes([0xFF, r, g, b, a])

    # End marker
    buf += bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
    return bytes(buf), w, h, "RGBA"

# ================================================================
# PNG Tests: Comprehensive
# ================================================================

def png_chunk(ctype, data):
    c = bytearray()
    c += struct.pack('>I', len(data))
    c += ctype
    c += data
    crc = zlib.crc32(bytes(c[4:])) & 0xFFFFFFFF
    c += struct.pack('>I', crc)
    return bytes(c)

PNG_SIG = bytes([137, 80, 78, 71, 13, 10, 26, 10])

def make_png_rgb_filtered(w=6, h=4):
    """6x4 PNG RGB 8-bit using filter Sub (type 1) for non-trivial filtering."""
    # Pixels: horizontal gradient R, vertical gradient G, diagonal gradient B
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(1)  # Filter Sub
        for x in range(w):
            r = x * 255 // (w - 1) if w > 1 else 0
            g = y * 255 // (h - 1) if h > 1 else 0
            b = (x + y) * 255 // (w + h - 2) if w + h > 2 else 0
            row.append(r)
            row.append(g)
            row.append(b)
        raw_rows.append(bytes(row))

    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)  # 8-bit RGB, no interlace
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB"

def make_png_rgba_paeth(w=5, h=5):
    """5x5 PNG RGBA 8-bit using filter Paeth (type 4)."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(4)  # Filter Paeth
        for x in range(w):
            r = (x * 50 + 10) % 256
            g = (y * 50 + 20) % 256
            b = ((x + y) * 30 + 30) % 256
            a = 255 - (x * 20 + y * 20) % 200
            row.append(r)
            row.append(g)
            row.append(b)
            row.append(a)
        raw_rows.append(bytes(row))

    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGBA"

def make_png_indexed(w=4, h=4):
    """4x4 PNG indexed color (color type 3) with PLTE palette."""
    # Palette of 4 colors
    palette = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])

    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(0)  # Filter None
        for x in range(w):
            row.append((x + y) % 4)  # 4 palette indices
        raw_rows.append(bytes(row))

    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 3, 0, 0, 0)  # 8-bit indexed
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'PLTE', palette)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGBA"

def make_png_grayscale_alpha(w=4, h=4):
    """4x4 PNG grayscale+alpha (color type 4) 8-bit."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(0)  # Filter None
        for x in range(w):
            gray = (x * 85) % 256
            alpha = (y * 85) % 256
            row.append(gray)
            row.append(alpha)
        raw_rows.append(bytes(row))

    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 4, 0, 0, 0)  # grayscale+alpha
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "GrayA"

def make_png_adam7(w=8, h=8):
    """8x8 PNG RGB 8-bit with Adam7 interlacing."""
    # Generate an 8x8 checkerboard pattern
    pixels = bytearray()
    for y in range(h):
        pixels.append(0)  # filter None
        for x in range(w):
            if (x + y) % 2 == 0:
                pixels.append(255); pixels.append(0); pixels.append(0)  # red
            else:
                pixels.append(0); pixels.append(0); pixels.append(255)  # blue

    compressed = zlib.compress(bytes(pixels))

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 1)  # interlace=1 (Adam7)
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB"

# ================================================================
# Generate and save all images
# ================================================================

print("Generating test images...\n")

images = []

# BMP
data, w, h, fmt = make_bmp_32bit_alpha(6, 4)
save_raw("real_bmp32.bmp", data)
images.append(("real_bmp32", data, w, h, fmt, "BMP 32-bit BGRA with alpha gradients"))

data, w, h, fmt = make_bmp_8bit_indexed(8, 4)
save_raw("real_bmp8.bmp", data)
images.append(("real_bmp8", data, w, h, fmt, "BMP 8-bit indexed with gradient palette"))

# TGA
data, w, h, fmt = make_tga_rgba_rle(6, 4)
save_raw("real_tga_rle.tga", data)
images.append(("real_tga_rle", data, w, h, fmt, "TGA Type 10 RLE RGBA 32-bit"))

data, w, h, fmt = make_tga_16bit(4, 4)
save_raw("real_tga_16.tga", data)
images.append(("real_tga_16", data, w, h, fmt, "TGA Type 2 16-bit A1R5G5B5 bottom-left"))

# QOI
data, w, h, fmt = make_qoi_diverse(8, 4)
save_raw("real_qoi_rgba.qoi", data)
images.append(("real_qoi_rgba", data, w, h, fmt, "QOI RGBA with diverse colors"))

# PNG
data, w, h, fmt = make_png_rgb_filtered(6, 4)
save_raw("real_png_rgb_sub.png", data)
images.append(("real_png_rgb_sub", data, w, h, fmt, "PNG RGB 8-bit with filter Sub"))

data, w, h, fmt = make_png_rgba_paeth(5, 5)
save_raw("real_png_rgba_paeth.png", data)
images.append(("real_png_rgba_paeth", data, w, h, fmt, "PNG RGBA 8-bit with filter Paeth"))

data, w, h, fmt = make_png_indexed(4, 4)
save_raw("real_png_indexed.png", data)
images.append(("real_png_indexed", data, w, h, fmt, "PNG indexed color with PLTE"))

data, w, h, fmt = make_png_grayscale_alpha(4, 4)
save_raw("real_png_graya.png", data)
images.append(("real_png_graya", data, w, h, fmt, "PNG grayscale+alpha 8-bit"))

data, w, h, fmt = make_png_adam7(8, 8)
save_raw("real_png_adam7.png", data)
images.append(("real_png_adam7", data, w, h, fmt, "PNG RGB Adam7 interlaced 8x8"))

# ================================================================
# Output MoonBit byte arrays
# ================================================================

print("\n\n=== MoonBit Byte Array Definitions ===")
print("// Copy the following into image_test.mbt:\n")

for name, data, w, h, fmt, desc in images:
    print(f"// {desc} ({w}x{h} {fmt})")
    print(bytes_to_mbt(name, data))
    print()

print(f"\nGenerated {len(images)} test images.")
