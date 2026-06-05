"""
Generate complex test images for MoonBit decoder stress testing.
Patterns designed to exercise different code paths in each decoder.
"""
import struct, zlib, os, hashlib, math

OUT = 'd:/moonbit-image/test_images'
os.makedirs(OUT, exist_ok=True)

# ============================================================
# Complex Pattern Generators
# ============================================================

def pattern_checkerboard(x, y, w, h):
    """Checkerboard: sharp edges every 8px, stresses RLE and filters"""
    return (255 if ((x//8) + (y//8)) % 2 == 0 else 0,
            255 if ((x//16) + (y//16)) % 2 == 0 else 0,
            255 if ((x//4) + (y//4)) % 2 == 0 else 0)

def pattern_gradient_radial(x, y, w, h):
    """Radial gradient from center: smooth transitions"""
    cx, cy = w/2, h/2
    dist = math.sqrt((x-cx)**2 + (y-cy)**2) / max(w, h) * 2
    dist = min(dist, 1.0)
    return (int(255 * dist), int(255 * (1 - dist)), int(128 + 127 * math.sin(dist * math.pi)))

def pattern_noise(x, y, w, h):
    """Deterministic noise: worst case for compression"""
    v = (x * 12345 + y * 67890 + x * y * 34567) & 0xFFFFFFFF
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)

def pattern_stripes(x, y, w, h):
    """Diagonal stripes: tests filter propagation across rows"""
    v = (x + y) % 64
    if v < 16:
        return (255, 0, 0)
    elif v < 32:
        return (0, 255, 0)
    elif v < 48:
        return (0, 0, 255)
    else:
        return (255, 255, 255)

def pattern_mandelbrot(x, y, w, h):
    """Mandelbrot-like fractal: heavy detail, stresses PNG filters"""
    scale = 3.5 / min(w, h)
    cx = (x - w/2) * scale - 0.5
    cy = (y - h/2) * scale
    zx, zy = 0.0, 0.0
    for i in range(64):
        if zx*zx + zy*zy > 4:
            v = int(i * 4.0)
            return (v, (v*3)%256, (v*7)%256)
        zx, zy = zx*zx - zy*zy + cx, 2*zx*zy + cy
    return (0, 0, 0)

def pattern_color_ramp(x, y, w, h):
    """Full color spectrum ramp: tests all 256 values per channel"""
    return (int(x / w * 255), int(y / h * 255), int(((x+y) / (w+h)) * 255))


PATTERNS = {
    "checkerboard":  pattern_checkerboard,
    "radial":        pattern_gradient_radial,
    "noise":         pattern_noise,
    "stripes":       pattern_stripes,
    "mandelbrot":    pattern_mandelbrot,
    "color_ramp":    pattern_color_ramp,
}


# ============================================================
# Image Encoders
# ============================================================

def make_bmp(w, h, pattern_fn):
    row_size = ((w * 3 + 3) // 4) * 4
    image_size = row_size * h
    buf = bytearray()
    buf += b'BM' + struct.pack('<I', 14+40+image_size) + struct.pack('<HH',0,0) + struct.pack('<I', 14+40)
    buf += struct.pack('<I',40) + struct.pack('<i',w) + struct.pack('<i',h) + struct.pack('<H',1) + struct.pack('<H',24)
    buf += struct.pack('<I',0) + struct.pack('<I',image_size) + struct.pack('<i',2835) + struct.pack('<i',2835)
    buf += struct.pack('<I',0) + struct.pack('<I',0)
    for y in range(h-1, -1, -1):
        for x in range(w):
            r, g, b = pattern_fn(x, y, w, h)
            buf += bytes([b, g, r])
        buf += bytes(row_size - w * 3)
    return bytes(buf)

def make_png(w, h, pattern_fn, color_type=2):
    ch = {0:1, 2:3, 4:2, 6:4}[color_type]
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter None
        for x in range(w):
            r, g, b = pattern_fn(x, y, w, h)
            raw.append(r)
            if ch >= 3:
                raw.append(g); raw.append(b)
            if ch in (4, 6):
                raw.append(255)
            if ch == 2:
                raw.append(255)
    compressed = zlib.compress(bytes(raw))
    buf = bytearray([137,80,78,71,13,10,26,10])
    for ct_bytes, data in [(b'IHDR', struct.pack('>IIBBBBB',w,h,8,color_type,0,0,0)),
                            (b'IDAT', compressed), (b'IEND', b'')]:
        c = struct.pack('>I',len(data)) + ct_bytes + data
        buf += c + struct.pack('>I', zlib.crc32(c[4:]) & 0xFFFFFFFF)
    return bytes(buf)

def make_tga(w, h, pattern_fn):
    buf = bytearray([0,0,2])+struct.pack('<HHB',0,0,0)+struct.pack('<HH',0,0)+struct.pack('<HH',w,h)+struct.pack('<BB',24,0x20)
    for y in range(h):
        for x in range(w):
            r, g, b = pattern_fn(x, y, w, h)
            buf += bytes([b, g, r])
    return bytes(buf)

def make_qoi(w, h, pattern_fn):
    buf = bytearray(b'qoif' + struct.pack('>II',w,h) + struct.pack('<BB',3,0))
    prev_r, prev_g, prev_b = 0, 0, 0
    for y in range(h):
        for x in range(w):
            r, g, b = pattern_fn(x, y, w, h)
            buf += bytes([0xFE, r, g, b])
            prev_r, prev_g, prev_b = r, g, b
    buf += bytes([0,0,0,0,0,0,0,1])
    return bytes(buf)


# ============================================================
# Generate images for each pattern
# ============================================================
sizes = [64, 256]
test_results = []

print("=" * 70)
print("Generating complex test images")
print("=" * 70)

for pattern_name, pattern_fn in PATTERNS.items():
    print(f"\n--- {pattern_name} ---")
    for size in sizes:
        for fmt_name, encoder in [("bmp", make_bmp), ("png", make_png),
                                   ("tga", make_tga), ("qoi", make_qoi)]:
            ext = {"bmp":"bmp","png":"png","tga":"tga","qoi":"qoi"}[fmt_name]
            fname = f"{fmt_name}_{pattern_name}_{size}x{size}.{ext}"
            data = encoder(size, size, pattern_fn)
            path = os.path.join(OUT, fname)
            with open(path, "wb") as f:
                f.write(data)
            kb = len(data) / 1024
            print(f"  {fname:45s} {len(data):>10,} bytes ({kb:>8.1f} KB)")
            if size == 256:
                test_results.append((fname, path, pattern_fn, size))


# ============================================================
# Verify with PIL
# ============================================================
print("\n" + "=" * 70)
print("PIL Verification (256x256 images)")
print("=" * 70)

from PIL import Image

all_pass = True
for fname, path, pattern_fn, size in test_results:
    try:
        img = Image.open(path).convert("RGBA")
        w, h = img.size
        errors = 0
        error_samples = []
        # Sample: check every 16th pixel + corners
        check_points = [(0,0), (0,h-1), (w-1,0), (w-1,h-1), (w//2, h//2)]
        check_points += [(x, y) for x in range(0, w, 16) for y in range(0, h, 16)]

        for x, y in check_points:
            r, g, b, _ = img.getpixel((x, y))
            er, eg, eb = pattern_fn(x, y, w, h)
            if r != er or g != eg or b != eb:
                if errors < 5:
                    error_samples.append(f"({x},{y}): exp=({er},{eg},{eb}) got=({r},{g},{b})")
                errors += 1

        checked = len(check_points)
        if errors == 0:
            print(f"  PASS: {fname:45s} {checked} pixels checked, 0 errors")
        else:
            print(f"  FAIL: {fname:45s} {errors}/{checked} errors")
            for e in error_samples:
                print(f"         {e}")
            all_pass = False
    except Exception as e:
        print(f"  ERROR: {fname:45s} {e}")
        all_pass = False

if all_pass:
    print("\n" + "=" * 70)
    print("ALL COMPLEX IMAGES VERIFIED CORRECTLY")
    print("=" * 70)
