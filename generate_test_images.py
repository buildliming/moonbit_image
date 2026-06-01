"""Generate test images for MoonBit image decoder testing."""
import struct
import zlib
import os

OUT_DIR = "d:/moonbit-image/test_images"
os.makedirs(OUT_DIR, exist_ok=True)

# ============================================================
# 1. BMP 2x2 24-bit BGR (bottom-up)
# ============================================================
# Row 0 (bottom): Red(255,0,0)=BGR(0,0,255), Green(0,255,0)=BGR(0,255,0)
# Row 1 (top):    Blue(0,0,255)=BGR(255,0,0),  White(255,255,255)=BGR(255,255,255)
# Each row: 6 bytes + 2 padding = 8 bytes
# Data offset: 14 + 40 = 54
# File size: 54 + 2*8 = 70

def make_bmp():
    width, height = 2, 2
    row_size = ((width * 3 + 3) // 4) * 4  # 8
    image_size = row_size * height  # 16
    file_size = 14 + 40 + image_size  # 70
    data_offset = 14 + 40  # 54

    buf = bytearray()
    # File header
    buf += b'BM'
    buf += struct.pack('<I', file_size)
    buf += struct.pack('<HH', 0, 0)
    buf += struct.pack('<I', data_offset)
    # DIB header (BITMAPINFOHEADER)
    buf += struct.pack('<I', 40)      # header size
    buf += struct.pack('<i', width)   # width
    buf += struct.pack('<i', height)  # height (positive = bottom-up)
    buf += struct.pack('<H', 1)       # planes
    buf += struct.pack('<H', 24)      # bpp
    buf += struct.pack('<I', 0)       # BI_RGB
    buf += struct.pack('<I', image_size)
    buf += struct.pack('<i', 2835)    # h-res (72 DPI)
    buf += struct.pack('<i', 2835)    # v-res
    buf += struct.pack('<I', 0)       # colors
    buf += struct.pack('<I', 0)       # important

    # Row 0 (bottom of image): Red (B=0,G=0,R=255), Green (B=0,G=255,R=0)
    buf += bytes([0, 0, 255])   # Red pixel: B,G,R
    buf += bytes([0, 255, 0])   # Green pixel: B,G,R
    buf += bytes([0, 0])        # padding
    # Row 1 (top of image): Blue (B=255,G=0,R=0), White (B=255,G=255,R=255)
    buf += bytes([255, 0, 0])   # Blue pixel: B,G,R
    buf += bytes([255, 255, 255]) # White pixel: B,G,R
    buf += bytes([0, 0])        # padding

    return bytes(buf)

# ============================================================
# 2. TGA 2x2 24-bit uncompressed true-color (Type 2, top-left origin)
# ============================================================
# Pixels (top→bottom, left→right):
#   Row 0: Red(255,0,0)=BGR(0,0,255), Green(0,255,0)=BGR(0,255,0)
#   Row 1: Blue(0,0,255)=BGR(255,0,0), White(255,255,255)=BGR(255,255,255)
# Image descriptor: bits 5-4 = 2 (top-left origin), alpha depth = 0 → 0x20

def make_tga():
    width, height = 2, 2
    buf = bytearray()
    buf += struct.pack('<B', 0)   # ID length
    buf += struct.pack('<B', 0)   # color map type
    buf += struct.pack('<B', 2)   # image type (uncompressed true-color)
    # Color map spec (5 bytes)
    buf += struct.pack('<H', 0)   # first entry index
    buf += struct.pack('<H', 0)   # color map length
    buf += struct.pack('<B', 0)   # color map entry size
    # Image spec (10 bytes)
    buf += struct.pack('<H', 0)   # x-origin
    buf += struct.pack('<H', 0)   # y-origin
    buf += struct.pack('<H', width)
    buf += struct.pack('<H', height)
    buf += struct.pack('<B', 24)  # pixel depth
    buf += struct.pack('<B', 0x20) # descriptor: top-left, 0 alpha bits

    # Pixel data (top→bottom, tightly packed, BGR order)
    # Row 0: Red, Green
    buf += bytes([0, 0, 255])      # Red
    buf += bytes([0, 255, 0])      # Green
    # Row 1: Blue, White
    buf += bytes([255, 0, 0])      # Blue
    buf += bytes([255, 255, 255])  # White

    return bytes(buf)

# ============================================================
# 3. QOI 2x2 RGB
# ============================================================
# Pixels: Red(255,0,0), Green(0,255,0), Blue(0,0,255), White(255,255,255)
# QOI encoding:
#   Pixel 0 (255,0,0,255): QOI_OP_RGB, then R=255, G=0, B=0
#   Pixel 1 (0,255,0,255): QOI_OP_RGB, then R=0, G=255, B=0
#   Pixel 2 (0,0,255,255): QOI_OP_RGB, then R=0, G=0, B=255
#   Pixel 3 (255,255,255,255): QOI_OP_RGB, then R=255, G=255, B=255
# End marker: 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x01

def make_qoi():
    width, height = 2, 2
    buf = bytearray()
    buf += b'qoif'
    buf += struct.pack('>I', width)
    buf += struct.pack('>I', height)
    buf += struct.pack('<B', 3)   # channels = RGB
    buf += struct.pack('<B', 0)   # colorspace = sRGB

    # Pixel 0: Red (255,0,0,255)
    buf += bytes([0xFE, 255, 0, 0])  # QOI_OP_RGB
    # Pixel 1: Green (0,255,0,255)
    buf += bytes([0xFE, 0, 255, 0])  # QOI_OP_RGB
    # Pixel 2: Blue (0,0,255,255)
    buf += bytes([0xFE, 0, 0, 255])  # QOI_OP_RGB
    # Pixel 3: White (255,255,255,255)
    buf += bytes([0xFE, 255, 255, 255])  # QOI_OP_RGB

    # End marker
    buf += bytes([0, 0, 0, 0, 0, 0, 0, 1])

    return bytes(buf)

# ============================================================
# 4. PNG 2x2 grayscale (8-bit)
# ============================================================
# Pixels: 0, 85, 170, 255 (row-major)
# Row 0: [0, 85]
# Row 1: [170, 255]
# Each row: filter byte + 2 pixels = 3 bytes
# Raw filtered data: [0, 0, 85, 0, 170, 255] = 6 bytes

def make_png():
    width, height = 2, 2
    # Raw pixel data with filter bytes
    raw_data = bytes([0, 0, 85, 0, 170, 255])  # filter None each row

    # Compress with zlib (raw deflate)
    compressed = zlib.compress(raw_data)

    def chunk(chunk_type, data):
        c = bytearray()
        c += struct.pack('>I', len(data))
        c += chunk_type
        c += data
        crc = zlib.crc32(bytes(c[4:])) & 0xFFFFFFFF
        c += struct.pack('>I', crc)
        return bytes(c)

    buf = bytearray()
    # PNG signature
    buf += bytes([137, 80, 78, 71, 13, 10, 26, 10])
    # IHDR
    ihdr = bytearray()
    ihdr += struct.pack('>I', width)
    ihdr += struct.pack('>I', height)
    ihdr += struct.pack('<B', 8)   # bit depth
    ihdr += struct.pack('<B', 0)   # color type (grayscale)
    ihdr += struct.pack('<B', 0)   # compression
    ihdr += struct.pack('<B', 0)   # filter
    ihdr += struct.pack('<B', 0)   # interlace
    buf += chunk(b'IHDR', bytes(ihdr))
    # IDAT
    buf += chunk(b'IDAT', compressed)
    # IEND
    buf += chunk(b'IEND', b'')
    return bytes(buf)

# ============================================================
# Write all test images
# ============================================================
images = {
    "test_bmp.bmp": make_bmp(),
    "test_tga.tga": make_tga(),
    "test_qoi.qoi": make_qoi(),
    "test_png.png": make_png(),
}

for name, data in images.items():
    path = os.path.join(OUT_DIR, name)
    with open(path, "wb") as f:
        f.write(data)
    print(f"Created {path} ({len(data)} bytes)")

print("\nAll test images generated successfully!")
