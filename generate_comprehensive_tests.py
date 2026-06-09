"""
Generate comprehensive test images for PNG, JPEG, GIF decoder testing.
Outputs both image files and MoonBit byte array code.
"""
import struct
import zlib
import os
from PIL import Image
import io

OUT = "d:/moonbit-image/test_images"
os.makedirs(OUT, exist_ok=True)

def save_raw(name, data):
    path = os.path.join(OUT, name)
    with open(path, "wb") as f:
        f.write(data)
    print(f"  Saved {name} ({len(data)} bytes)")

def bytes_to_mbt(name, data):
    """Convert bytes to a MoonBit make_bytes array literal."""
    name_clean = name.replace('.', '_').replace('-', '_')
    lines = []
    lines.append(f"fn make_{name_clean}() -> Bytes {{")
    lines.append("  make_bytes([")
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_vals = ", ".join(f"0x{b:02X}" for b in chunk)
        if i + 16 < len(data):
            lines.append(f"    {hex_vals},")
        else:
            lines.append(f"    {hex_vals}")
    lines.append("  ])")
    lines.append("}")
    return "\n".join(lines)

# ================================================================
# PNG Helpers
# ================================================================
PNG_SIG = bytes([137, 80, 78, 71, 13, 10, 26, 10])

def png_chunk(ctype, data):
    c = bytearray()
    c += struct.pack('>I', len(data))
    c += ctype
    c += data
    crc = zlib.crc32(bytes(c[4:])) & 0xFFFFFFFF
    c += struct.pack('>I', crc)
    return bytes(c)

# ================================================================
# PNG Filter Up test (6x4)
# ================================================================
def make_png_filter_up(w=6, h=4):
    """6x4 PNG RGB 8-bit using filter Up (type 2)."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(2)  # Filter Up
        for x in range(w):
            r = min(255, (x * 40 + y * 15) % 256)
            g = min(255, (y * 60 + x * 10) % 256)
            b = min(255, ((x + y) * 30) % 256)
            row.append(r)
            row.append(g)
            row.append(b)
        raw_rows.append(bytes(row))
    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB"

# ================================================================
# PNG Filter Average test (6x4)
# ================================================================
def make_png_filter_avg(w=6, h=4):
    """6x4 PNG RGB 8-bit using filter Average (type 3)."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(3)  # Filter Average
        for x in range(w):
            r = min(255, x * 42 % 256)
            g = min(255, y * 63 % 256)
            b = min(255, ((x * y) * 7) % 256)
            row.append(r)
            row.append(g)
            row.append(b)
        raw_rows.append(bytes(row))
    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB"

# ================================================================
# PNG 16-bit grayscale (4x4)
# ================================================================
def make_png_16bit_gray(w=4, h=4):
    """4x4 PNG 16-bit grayscale."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(0)  # Filter None
        for x in range(w):
            val = (x * 85 + y * 85) * 257  # scales to 16-bit range
            row.append((val >> 8) & 0xFF)
            row.append(val & 0xFF)
        raw_rows.append(bytes(row))
    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 16, 0, 0, 0, 0)
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "Gray8"

# ================================================================
# PNG 16-bit RGB (4x4)
# ================================================================
def make_png_16bit_rgb(w=4, h=4):
    """4x4 PNG 16-bit RGB."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(0)  # Filter None
        for x in range(w):
            r = (x * 85) * 257
            g = (y * 85) * 257
            b = ((x + y) * 42) * 257
            for v in [r, g, b]:
                row.append((v >> 8) & 0xFF)
                row.append(v & 0xFF)
        raw_rows.append(bytes(row))
    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 16, 2, 0, 0, 0)
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB8"

# ================================================================
# PNG multi-IDAT (split decompressed data across multiple IDATs)
# ================================================================
def make_png_multi_idat(w=6, h=4):
    """6x4 PNG RGB with multiple IDAT chunks."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        row.append(0)  # Filter None
        for x in range(w):
            r = x * 42 % 256
            g = y * 63 % 256
            b = (x + y) * 30 % 256
            row.append(r); row.append(g); row.append(b)
        raw_rows.append(bytes(row))
    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    # Split into 3 IDAT chunks
    third = len(compressed) // 3
    parts = [compressed[:third], compressed[third:2*third], compressed[2*third:]]

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    buf += png_chunk(b'IHDR', ihdr)
    for p in parts:
        buf += png_chunk(b'IDAT', p)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB"

# ================================================================
# PNG larger Adam7 (16x16) — less likely to hit small-image boundary issues
# ================================================================
def make_png_adam7_16(w=16, h=16):
    """16x16 PNG RGB 8-bit with Adam7 interlacing."""
    pixels = bytearray()
    for y in range(h):
        pixels.append(0)  # filter None
        for x in range(w):
            r = x * 16 % 256
            g = y * 16 % 256
            b = ((x + y) * 8) % 256
            pixels.append(r); pixels.append(g); pixels.append(b)
    compressed = zlib.compress(bytes(pixels))

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 1)  # interlace=1
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGB"

# ================================================================
# PNG with all filter types mixed (6x6)
# ================================================================
def make_png_mixed_filters(w=6, h=6):
    """6x6 PNG RGBA with alternating filter types per row."""
    raw_rows = []
    for y in range(h):
        row = bytearray()
        ft = y % 5  # Cycle through None(0), Sub(1), Up(2), Avg(3), Paeth(4)
        row.append(ft)
        for x in range(w):
            r = (x * 40 + y * 10) % 256
            g = (y * 40 + x * 15) % 256
            b = ((x + y) * 25) % 256
            a = 255
            row.append(r); row.append(g); row.append(b); row.append(a)
        raw_rows.append(bytes(row))
    raw_data = b''.join(raw_rows)
    compressed = zlib.compress(raw_data)

    buf = bytearray()
    buf += PNG_SIG
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    buf += png_chunk(b'IHDR', ihdr)
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf), w, h, "RGBA"

# ================================================================
# JPEG Helpers — Generate proper JPEG via PIL
# ================================================================

# ================================================================
# JPEG YCbCr color (8x8)
# ================================================================
def make_jpeg_color(w=8, h=8):
    """8x8 JPEG YCbCr color with 4:4:4 sampling."""
    img = Image.new('RGB', (w, h))
    pixels = []
    for y in range(h):
        for x in range(w):
            r = x * 32 % 256
            g = y * 32 % 256
            b = ((x + y) * 16) % 256
            pixels.append((r, g, b))
    img.putdata(pixels)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=95, subsampling=0)  # subsampling=0 = 4:4:4
    return buf.getvalue(), w, h, "RGB8"

# ================================================================
# JPEG YCbCr 4:2:0 subsampling (16x16)
# ================================================================
def make_jpeg_420(w=16, h=16):
    """16x16 JPEG YCbCr with 4:2:0 chroma subsampling."""
    img = Image.new('RGB', (w, h))
    pixels = []
    for y in range(h):
        for x in range(w):
            r = (x * 16 + y * 4) % 256
            g = (y * 16 + x * 4) % 256
            b = ((x + y) * 10) % 256
            pixels.append((r, g, b))
    img.putdata(pixels)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=90, subsampling=2)  # 2 = 4:2:0
    return buf.getvalue(), w, h, "RGB8"

# ================================================================
# JPEG 4:2:2 subsampling (16x16)
# ================================================================
def make_jpeg_422(w=16, h=16):
    """16x16 JPEG YCbCr with 4:2:2 chroma subsampling."""
    img = Image.new('RGB', (w, h))
    pixels = []
    for y in range(h):
        for x in range(w):
            r = (x * 20) % 256
            g = (y * 20) % 256
            b = 128
            pixels.append((r, g, b))
    img.putdata(pixels)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=90, subsampling=1)  # 1 = 4:2:2
    return buf.getvalue(), w, h, "RGB8"

# ================================================================
# JPEG with restart markers (32x32, grayscale to trigger RSTs)
# ================================================================
def make_jpeg_rst(w=32, h=32):
    """32x32 grayscale JPEG with restart markers."""
    img = Image.new('L', (w, h))
    pixels = []
    for y in range(h):
        for x in range(w):
            pixels.append((x * 8 + y * 4) % 256)
    img.putdata(pixels)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=85, restart_markers=True)
    return buf.getvalue(), w, h, "Gray8"

# ================================================================
# JPEG non-8x8-multiple size (10x10 grayscale)
# ================================================================
def make_jpeg_10x10(w=10, h=10):
    """10x10 grayscale JPEG (non-MCU-aligned dimensions)."""
    img = Image.new('L', (w, h))
    pixels = []
    for y in range(h):
        for x in range(w):
            # Checkerboard pattern
            pixels.append(255 if (x + y) % 2 == 0 else 0)
    img.putdata(pixels)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=95)
    return buf.getvalue(), w, h, "Gray8"

# ================================================================
# JPEG 12x12 YCbCr color (non-8x8-multiple)
# ================================================================
def make_jpeg_color_12x12(w=12, h=12):
    """12x12 JPEG YCbCr color (non-MCU-aligned)."""
    img = Image.new('RGB', (w, h))
    pixels = []
    for y in range(h):
        for x in range(w):
            r = (x * 21) % 256
            g = (y * 21) % 256
            b = ((x + y) * 10) % 256
            pixels.append((r, g, b))
    img.putdata(pixels)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=95, subsampling=0)
    return buf.getvalue(), w, h, "RGB8"

# ================================================================
# GIF Helpers
# ================================================================

def make_gif_interlaced(w=8, h=8):
    """8x8 interlaced GIF with grayscale gradient."""
    # Raw pixel pattern: horizontal gradient
    indices = []
    for y in range(h):
        for x in range(w):
            indices.append((x + y) % 16)

    # Build palette (16 grayscale entries)
    palette = []
    for i in range(16):
        v = i * 17
        palette.append((v, v, v))
    while len(palette) < 256:
        palette.append((0, 0, 0))

    # Build GIF with interlace
    buf = bytearray(b'GIF89a')
    buf += struct.pack('<HH', w, h)
    packed = 0xF0 | 7  # GCT present, size=256
    buf += struct.pack('<B', packed)
    buf += struct.pack('<B', 0)  # bg color index
    buf += struct.pack('<B', 0)  # pixel aspect ratio
    for r, g, b in palette:
        buf += struct.pack('BBB', r, g, b)

    # Image descriptor with interlace
    buf += struct.pack('<B', 0x2C)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<HH', w, h)
    buf += struct.pack('<B', 0x40)  # interlace bit set

    # LZW encode
    min_code_size = 8
    lzw_data = lzw_encode_16(indices, min_code_size)

    buf += struct.pack('<B', min_code_size)
    pos = 0
    while pos < len(lzw_data):
        blen = min(255, len(lzw_data) - pos)
        buf += struct.pack('<B', blen) + lzw_data[pos:pos+blen]
        pos += blen
    buf += struct.pack('<B', 0)  # block terminator
    buf += struct.pack('<B', 0x3B)  # trailer
    return bytes(buf), w, h, "RGBA"

def lzw_encode_16(indices, min_code_size):
    """Simple LZW encoder for 16-color palette."""
    table_prefix = [-1] * 4096
    table_suffix = list(range(4096))
    next_code = 16 + 2
    code_size = min_code_size + 1
    max_code = (1 << code_size) - 1
    clear_code = 16
    eoi_code = 17
    out_bits = []

    def write_code(code, bits):
        for i in range(bits):
            out_bits.append((code >> i) & 1)

    write_code(clear_code, code_size)
    cur = indices[0]
    for idx in indices[1:]:
        found = -1
        for c in range(18, next_code):
            if c < 4096 and table_prefix[c] == cur and table_suffix[c] == idx:
                found = c
                break
        if found >= 0:
            cur = found
        else:
            write_code(cur, code_size)
            if next_code < 4096:
                table_prefix[next_code] = cur
                table_suffix[next_code] = idx
                next_code += 1
                if next_code > max_code and code_size < 12:
                    code_size += 1
                    max_code_tmp = (1 << code_size) - 1
            cur = idx
    write_code(cur, code_size)
    write_code(eoi_code, code_size)

    while len(out_bits) % 8:
        out_bits.append(0)
    data_bytes = bytearray()
    for i in range(0, len(out_bits), 8):
        byte = 0
        for j in range(8):
            byte |= out_bits[i + j] << j
        data_bytes.append(byte)
    return bytes(data_bytes)

def make_gif_transparent(w=8, h=8):
    """8x8 GIF with transparent background (GCE)."""
    indices = []
    for y in range(h):
        for x in range(w):
            if x < 4 and y < 4:
                indices.append(1)  # transparent
            else:
                indices.append(2 + (x + y) % 4)  # colored

    palette = [(0, 0, 0), (128, 128, 128), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
    while len(palette) < 256:
        palette.append((0, 0, 0))

    buf = bytearray(b'GIF89a')
    buf += struct.pack('<HH', w, h)
    packed = 0xF0 | 7
    buf += struct.pack('<B', packed)
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0)
    for r, g, b in palette:
        buf += struct.pack('BBB', r, g, b)

    # Graphic Control Extension (GCE)
    buf += struct.pack('<B', 0x21)  # extension introducer
    buf += struct.pack('<B', 0xF9)  # GCE label
    buf += struct.pack('<B', 4)     # block size
    buf += struct.pack('<B', 1)     # packed: transparency flag = 1
    buf += struct.pack('<H', 50)    # delay = 50 centiseconds
    buf += struct.pack('<B', 1)     # transparent color index = 1
    buf += struct.pack('<B', 0)     # block terminator

    # Image descriptor
    buf += struct.pack('<B', 0x2C)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<HH', w, h)
    buf += struct.pack('<B', 0x00)  # no local color table, no interlace

    min_code_size = 8
    lzw_data = lzw_encode_8bpc(indices, min_code_size)

    buf += struct.pack('<B', min_code_size)
    pos = 0
    while pos < len(lzw_data):
        blen = min(255, len(lzw_data) - pos)
        buf += struct.pack('<B', blen) + lzw_data[pos:pos+blen]
        pos += blen
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0x3B)
    return bytes(buf), w, h, "RGBA"

def lzw_encode_8bpc(indices, min_code_size):
    """LZW encoder for 8-bits-per-code images."""
    table_prefix = [-1] * 4096
    table_suffix = list(range(4096))
    next_code = 258
    code_size = min_code_size + 1
    max_code = (1 << code_size) - 1
    clear_code = 256
    eoi_code = 257
    out_bits = []

    def write_code(code, bits):
        for i in range(bits):
            out_bits.append((code >> i) & 1)

    write_code(clear_code, code_size)
    cur = indices[0]
    for idx in indices[1:]:
        found = -1
        for c in range(258, next_code):
            if c < 4096 and table_prefix[c] == cur and table_suffix[c] == idx:
                found = c
                break
        if found >= 0:
            cur = found
        else:
            write_code(cur, code_size)
            if next_code < 4096:
                table_prefix[next_code] = cur
                table_suffix[next_code] = idx
                next_code += 1
                if next_code > max_code and code_size < 12:
                    code_size += 1
                    max_code = (1 << code_size) - 1
            cur = idx
    write_code(cur, code_size)
    write_code(eoi_code, code_size)

    while len(out_bits) % 8:
        out_bits.append(0)
    data_bytes = bytearray()
    for i in range(0, len(out_bits), 8):
        byte = 0
        for j in range(8):
            byte |= out_bits[i + j] << j
        data_bytes.append(byte)
    return bytes(data_bytes)

def make_gif_local_palette(w=6, h=6):
    """6x6 GIF with local color table (different from global)."""
    # Global palette: grayscale
    global_pal = [(i*30, i*30, i*30) for i in range(9)]
    while len(global_pal) < 256:
        global_pal.append((0, 0, 0))

    # Local palette: color (only 4 entries for simplicity)
    local_pal = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]

    indices = []
    for y in range(h):
        for x in range(w):
            indices.append((x + y) % 4)

    buf = bytearray(b'GIF89a')
    buf += struct.pack('<HH', w, h)
    packed = 0xF0 | 7
    buf += struct.pack('<B', packed)
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0)
    for r, g, b in global_pal:
        buf += struct.pack('BBB', r, g, b)

    # Image descriptor with local color table
    buf += struct.pack('<B', 0x2C)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<HH', w, h)
    # Local color table: 4 entries (2^2), so size field = 1 (2^(1+1)=4)
    buf += struct.pack('<B', 0x81)  # LCT present, size=1 (=4 entries), no interlace

    for r, g, b in local_pal:
        buf += struct.pack('BBB', r, g, b)
    while len(local_pal) < 4:
        local_pal.append((0, 0, 0))

    min_code_size = 2  # 4 colors = 2 bits
    lzw_data = lzw_encode_small(indices, min_code_size)

    buf += struct.pack('<B', min_code_size)
    pos = 0
    while pos < len(lzw_data):
        blen = min(255, len(lzw_data) - pos)
        buf += struct.pack('<B', blen) + lzw_data[pos:pos+blen]
        pos += blen
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0x3B)
    return bytes(buf), w, h, "RGBA"

def lzw_encode_small(indices, min_code_size):
    """LZW encoder for small-code images."""
    table_prefix = [-1] * 4096
    table_suffix = list(range(4096))
    clear_code = 1 << min_code_size
    eoi_code = clear_code + 1
    next_code = eoi_code + 1
    code_size = min_code_size + 1
    max_code = (1 << code_size) - 1
    out_bits = []

    def write_code(code, bits):
        for i in range(bits):
            out_bits.append((code >> i) & 1)

    write_code(clear_code, code_size)
    cur = indices[0]
    for idx in indices[1:]:
        found = -1
        for c in range(next_code - (next_code - clear_code - 1) if False else eoi_code + 1, next_code):
            if c < 4096 and table_prefix[c] == cur and table_suffix[c] == idx:
                found = c
                break
        if found >= 0:
            cur = found
        else:
            write_code(cur, code_size)
            if next_code < 4096:
                table_prefix[next_code] = cur
                table_suffix[next_code] = idx
                next_code += 1
                if next_code > max_code and code_size < 12:
                    code_size += 1
                    max_code = (1 << code_size) - 1
            cur = idx
    write_code(cur, code_size)
    write_code(eoi_code, code_size)

    while len(out_bits) % 8:
        out_bits.append(0)
    data_bytes = bytearray()
    for i in range(0, len(out_bits), 8):
        byte = 0
        for j in range(8):
            byte |= out_bits[i + j] << j
        data_bytes.append(byte)
    return bytes(data_bytes)

# ================================================================
# Animated GIF (2 frames)
# ================================================================
def make_gif_animated(w=6, h=6):
    """Animated 6x6 GIF with 2 frames."""
    indices_frame1 = []
    indices_frame2 = []
    for y in range(h):
        for x in range(w):
            indices_frame1.append(0 if (x + y) % 2 == 0 else 1)
            indices_frame2.append(2 if (x + y) % 2 == 0 else 3)

    palette = [(255, 0, 0), (0, 0, 255), (0, 255, 0), (255, 255, 0)]
    while len(palette) < 256:
        palette.append((0, 0, 0))

    buf = bytearray(b'GIF89a')
    buf += struct.pack('<HH', w, h)
    packed = 0xF0 | 7
    buf += struct.pack('<B', packed)
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0)
    for r, g, b in palette:
        buf += struct.pack('BBB', r, g, b)

    # Netscape Application Extension (loop count)
    buf += b'\x21\xFF\x0B'  # extension + app label + block size
    buf += b'NETSCAPE2.0'
    buf += b'\x03\x01'  # sub-block
    buf += struct.pack('<H', 0)  # loop count = infinite
    buf += b'\x00'  # block terminator

    # Frame 1
    buf += struct.pack('<B', 0x21)  # extension
    buf += struct.pack('<B', 0xF9)  # GCE
    buf += struct.pack('<B', 4)     # block size
    buf += struct.pack('<B', 0)     # packed: no transparency
    buf += struct.pack('<H', 100)   # delay = 100 cs = 1 second
    buf += struct.pack('<B', 0)     # transparent index
    buf += struct.pack('<B', 0)     # terminator

    buf += struct.pack('<B', 0x2C)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<HH', w, h)
    buf += struct.pack('<B', 0x00)

    min_code_size1 = 2
    lzw_data1 = lzw_encode_small(indices_frame1, min_code_size1)
    buf += struct.pack('<B', min_code_size1)
    pos = 0
    while pos < len(lzw_data1):
        blen = min(255, len(lzw_data1) - pos)
        buf += struct.pack('<B', blen) + lzw_data1[pos:pos+blen]
        pos += blen
    buf += struct.pack('<B', 0)

    # Frame 2
    buf += struct.pack('<B', 0x21)
    buf += struct.pack('<B', 0xF9)
    buf += struct.pack('<B', 4)
    buf += struct.pack('<B', 0)
    buf += struct.pack('<H', 200)   # delay = 200 cs = 2 seconds
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0)

    buf += struct.pack('<B', 0x2C)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<HH', w, h)
    buf += struct.pack('<B', 0x00)

    lzw_data2 = lzw_encode_small(indices_frame2, min_code_size1)
    buf += struct.pack('<B', min_code_size1)
    pos = 0
    while pos < len(lzw_data2):
        blen = min(255, len(lzw_data2) - pos)
        buf += struct.pack('<B', blen) + lzw_data2[pos:pos+blen]
        pos += blen
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0x3B)

    return bytes(buf), w, h, "RGBA"

# ================================================================
# Generate everything
# ================================================================

print("Generating comprehensive test images...\n")

all_images = []

# PNG tests
tests = [
    ("png_filter_up", make_png_filter_up()),
    ("png_filter_avg", make_png_filter_avg()),
    ("png_16bit_gray", make_png_16bit_gray()),
    ("png_16bit_rgb", make_png_16bit_rgb()),
    ("png_multi_idat", make_png_multi_idat()),
    ("png_adam7_16", make_png_adam7_16()),
    ("png_mixed_filters", make_png_mixed_filters()),
]

# JPEG tests
tests += [
    ("jpg_color_8x8", make_jpeg_color()),
    ("jpg_420_16x16", make_jpeg_420()),
    ("jpg_422_16x16", make_jpeg_422()),
    ("jpg_rst_32x32", make_jpeg_rst()),
    ("jpg_10x10", make_jpeg_10x10()),
    ("jpg_color_12x12", make_jpeg_color_12x12()),
]

# GIF tests
tests += [
    ("gif_interlaced_8x8", make_gif_interlaced()),
    ("gif_transparent_8x8", make_gif_transparent()),
    ("gif_local_palette_6x6", make_gif_local_palette()),
    ("gif_animated_6x6", make_gif_animated()),
]

for name, (data, w, h, fmt) in tests:
    fname = name + (".png" if name.startswith("png") else
                    ".jpg" if name.startswith("jpg") else ".gif")
    save_raw(fname, data)
    all_images.append((name, data, w, h, fmt))

# ================================================================
# Output MoonBit byte array code
# ================================================================
print("\n\n=== MoonBit Byte Array Definitions ===\n")
for name, data, w, h, fmt in all_images:
    print(f"// {name}: {w}x{h} {fmt}")
    print(bytes_to_mbt(name, data))
    print()

print(f"\nTotal: {len(all_images)} test images generated.")
