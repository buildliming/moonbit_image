"""
Generate MoonBit test file with embedded 128x128 complex images.
Also generate 2048x2048 TGA + QOI images for large-size testing.
"""
import struct, zlib, os, math

OUT = 'd:/moonbit-image/test_images'
MBT = 'd:/moonbit-image/complex_image_test.mbt'
os.makedirs(OUT, exist_ok=True)

# ============================================================
# Pattern generators
# ============================================================
def pattern_checkerboard(x, y, w, h):
    return (255 if ((x//8)+(y//8))%2==0 else 0,
            255 if ((x//16)+(y//16))%2==0 else 0,
            255 if ((x//4)+(y//4))%2==0 else 0)

def pattern_radial(x, y, w, h):
    cx, cy = w/2, h/2
    d = min(math.sqrt((x-cx)**2+(y-cy)**2)/max(w,h)*2, 1.0)
    return (int(255*d), int(255*(1-d)), int(128+127*math.sin(d*math.pi)))

def pattern_noise(x, y, w, h):
    v = (x*12345 + y*67890 + x*y*34567) & 0xFFFFFFFF
    return ((v>>16)&0xFF, (v>>8)&0xFF, v&0xFF)

def pattern_mandelbrot(x, y, w, h):
    scale = 3.5/min(w,h)
    cx, cy = (x-w/2)*scale-0.5, (y-h/2)*scale
    zx, zy = 0.0, 0.0
    for i in range(64):
        if zx*zx+zy*zy>4:
            v = int(i*4.0)
            return (v, (v*3)%256, (v*7)%256)
        zx, zy = zx*zx-zy*zy+cx, 2*zx*zy+cy
    return (0,0,0)

# ============================================================
# Encoders
# ============================================================
def make_bmp(w, h, fn):
    row_size = ((w*3+3)//4)*4
    image_size = row_size*h
    buf = bytearray()
    buf += b'BM'+struct.pack('<I',14+40+image_size)+struct.pack('<HH',0,0)+struct.pack('<I',14+40)
    buf += struct.pack('<I',40)+struct.pack('<i',w)+struct.pack('<i',h)+struct.pack('<H',1)+struct.pack('<H',24)
    buf += struct.pack('<I',0)+struct.pack('<I',image_size)+struct.pack('<i',2835)+struct.pack('<i',2835)
    buf += struct.pack('<I',0)+struct.pack('<I',0)
    for y in range(h-1,-1,-1):
        for x in range(w): r,g,b = fn(x,y,w,h); buf += bytes([b,g,r])
        buf += bytes(row_size-w*3)
    return bytes(buf)

def make_png(w, h, fn, ct=2):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            r,g,b = fn(x,y,w,h); raw += bytes([r,g,b])
    compressed = zlib.compress(bytes(raw))
    buf = bytearray([137,80,78,71,13,10,26,10])
    for ctyp, data in [(b'IHDR',struct.pack('>IIBBBBB',w,h,8,ct,0,0,0)),(b'IDAT',compressed),(b'IEND',b'')]:
        c = struct.pack('>I',len(data))+ctyp+data
        buf += c+struct.pack('>I',zlib.crc32(c[4:])&0xFFFFFFFF)
    return bytes(buf)

def make_tga(w, h, fn):
    buf = bytearray([0,0,2])+struct.pack('<HHB',0,0,0)+struct.pack('<HH',0,0)+struct.pack('<HH',w,h)+struct.pack('<BB',24,0x20)
    for y in range(h):
        for x in range(w): r,g,b = fn(x,y,w,h); buf += bytes([b,g,r])
    return bytes(buf)

def make_qoi(w, h, fn):
    buf = bytearray(b'qoif'+struct.pack('>II',w,h)+struct.pack('<BB',3,0))
    for y in range(h):
        for x in range(w): r,g,b = fn(x,y,w,h); buf += bytes([0xFE,r,g,b])
    buf += bytes([0,0,0,0,0,0,0,1])
    return bytes(buf)

# ============================================================
# Bytes to MoonBit array helper
# ============================================================
def to_mbt(data, indent=4):
    prefix = " "*indent
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        lines.append(prefix + ", ".join(f"0x{b:02X}" for b in chunk) + ",")
    return "\n".join(lines)

# ============================================================
# Compute checksums for verification
# ============================================================
def checksums(w, h, fn):
    sr, sg, sb = 0, 0, 0
    for y in range(h):
        for x in range(w):
            r,g,b = fn(x,y,w,h)
            sr += r; sg += g; sb += b
    return sr, sg, sb

# ============================================================
# Generate 2048x2048 TGA + QOI (large test)
# ============================================================
print("=" * 60)
print("Generating 2048x2048 TGA + QOI images...")
print("=" * 60)

for pattern_name, pattern_fn in [("checkerboard", pattern_checkerboard),
                                   ("noise", pattern_noise),
                                   ("radial", pattern_radial)]:
    for fmt, encoder, ext in [("tga", make_tga, "tga"), ("qoi", make_qoi, "qoi")]:
        fname = f"{fmt}_{pattern_name}_2048x2048.{ext}"
        data = encoder(2048, 2048, pattern_fn)
        path = os.path.join(OUT, fname)
        with open(path, "wb") as f: f.write(data)
        print(f"  {fname:50s} {len(data):>14,} bytes ({len(data)/1024/1024:.2f} MB)")

# ============================================================
# Verify TGA 2048x2048 pixel data directly (no PIL needed)
# ============================================================
print("\n" + "=" * 60)
print("Verifying 2048x2048 TGA pixel data (raw byte comparison)...")
print("=" * 60)

for pattern_name, pattern_fn in [("checkerboard", pattern_checkerboard),
                                   ("noise", pattern_noise),
                                   ("radial", pattern_radial)]:
    path = os.path.join(OUT, f"tga_{pattern_name}_2048x2048.tga")
    with open(path, "rb") as f:
        data = f.read()
    # TGA header is 18 bytes, pixel data starts at offset 18
    pixel_data = data[18:]
    w, h = 2048, 2048
    errors = 0
    for y in range(0, h, 128):
        for x in range(0, w, 128):
            offset = (y * w + x) * 3
            b, g, r = pixel_data[offset], pixel_data[offset+1], pixel_data[offset+2]
            er, eg, eb = pattern_fn(x, y, w, h)
            if r != er or g != eg or b != eb:
                errors += 1
    status = "PASS" if errors == 0 else f"FAIL({errors})"
    print(f"  tga_{pattern_name}_2048x2048.tga: {status} (256 samples)")

# ============================================================
# Generate MoonBit test file (128x128 complex images)
# ============================================================
print("\n" + "=" * 60)
print("Generating MoonBit embedded tests (128x128)...")
print("=" * 60)

TEST_SIZE = 128

code = []
code.append('// Complex image tests (128x128) - Auto-generated')
code.append('')
code.append('fn complex_checksum(img : Image) -> (Int, Int, Int) {')
code.append('  let mut sr = 0')
code.append('  let mut sg = 0')
code.append('  let mut sb = 0')
code.append('  for y = 0; y < img.height; y = y + 1 {')
code.append('    for x = 0; x < img.width; x = x + 1 {')
code.append('      let c = img.get_pixel(x, y)')
code.append('      sr = sr + c.r')
code.append('      sg = sg + c.g')
code.append('      sb = sb + c.b')
code.append('    }')
code.append('  }')
code.append('  (sr, sg, sb)')
code.append('}')
code.append('')

fmt_map = {"bmp": ("decode_bmp", "RGB8"), "tga": ("decode_tga", "RGBA8"),
           "png": ("decode_png", "RGB8"), "qoi": ("decode_qoi", "RGBA8")}

for pattern_name, pattern_fn in [("checkerboard", pattern_checkerboard),
                                   ("radial", pattern_radial),
                                   ("noise", pattern_noise),
                                   ("mandelbrot", pattern_mandelbrot)]:
    sr, sg, sb = checksums(TEST_SIZE, TEST_SIZE, pattern_fn)

    for fmt_name in ["bmp", "png", "tga", "qoi"]:
        decoder_fn, expected_fmt = fmt_map[fmt_name]
        ext = fmt_name
        encoder = {"bmp": make_bmp, "png": make_png, "tga": make_tga, "qoi": make_qoi}[fmt_name]
        data = encoder(TEST_SIZE, TEST_SIZE, pattern_fn)

        tag = f"{fmt_name}_{pattern_name}_128"
        var_name = f"make_{tag}"
        test_name = f"complex_{tag}"

        # Save binary
        path = os.path.join(OUT, f"{tag}.{ext}")
        with open(path, "wb") as f: f.write(data)
        kb = len(data)/1024

        code.append(f'// {pattern_name} pattern, {fmt_name.upper()} format ({kb:.1f} KB)')
        code.append(f'fn {var_name}() -> Bytes {{')
        code.append('  make_bytes([')
        code.append(to_mbt(data))
        code.append('  ])')
        code.append('}')
        code.append('')
        code.append(f'test "complex_{tag}" {{')
        code.append(f'  let img = {decoder_fn}({var_name}())')
        code.append(f'  check_dims(img, {TEST_SIZE}, {TEST_SIZE})')
        code.append(f'  match img.format {{')
        if expected_fmt == "RGB8":
            code.append(f'    PixelFormat::RGB8 => ()')
        else:
            code.append(f'    PixelFormat::RGBA8 => ()')
        code.append(f'    _ => raise Failure::Failure("Expected {expected_fmt} format")')
        code.append(f'  }}')
        # Corner pixel checks
        for cx, cy in [(0,0), (TEST_SIZE-1,0), (0,TEST_SIZE-1), (TEST_SIZE-1,TEST_SIZE-1), (TEST_SIZE//2,TEST_SIZE//2)]:
            er, eg, eb = pattern_fn(cx, cy, TEST_SIZE, TEST_SIZE)
            code.append(f'  check_pixel(img, {cx}, {cy}, {er}, {eg}, {eb}, 255)')
        # Full checksum
        code.append(f'  let (sr, sg, sb) = complex_checksum(img)')
        code.append(f'  if sr != {sr} {{ raise Failure::Failure("R-checksum mismatch: got " + sr.to_string() + ", expected {sr}") }}')
        code.append(f'  if sg != {sg} {{ raise Failure::Failure("G-checksum mismatch: got " + sg.to_string() + ", expected {sg}") }}')
        code.append(f'  if sb != {sb} {{ raise Failure::Failure("B-checksum mismatch: got " + sb.to_string() + ", expected {sb}") }}')
        code.append(f'  println("Complex {tag} test passed!")')
        code.append('}')
        code.append('')

        print(f"  {tag:45s} {len(data):>10,} bytes  checksum=({sr},{sg},{sb})")

with open(MBT, "w", encoding="utf-8") as f:
    f.write("\n".join(code))

lines = len(code)
print(f"\nGenerated {MBT} ({len(code)} lines)")

# ============================================================
# Verify TGA 128 pixel data directly
# ============================================================
print("\nVerifying TGA 128x128 raw pixel data...")
for pattern_name, pattern_fn in [("checkerboard", pattern_checkerboard),
                                   ("radial", pattern_radial),
                                   ("noise", pattern_noise),
                                   ("mandelbrot", pattern_mandelbrot)]:
    path = os.path.join(OUT, f"tga_{pattern_name}_128.tga")
    with open(path, "rb") as f: f.read(18); pixel_data = f.read()
    errors = sum(1 for y in range(128) for x in range(128)
                 if (b:=pixel_data[(y*128+x)*3], g:=pixel_data[(y*128+x)*3+1], r:=pixel_data[(y*128+x)*3+2],
                     er:=pattern_fn(x,y,128,128), r!=er[0] or g!=er[1] or b!=er[2])[0])
    # Simpler:
    errors = 0
    for y in range(128):
        for x in range(128):
            off = (y*128+x)*3
            b, g, r = pixel_data[off], pixel_data[off+1], pixel_data[off+2]
            er, eg, eb = pattern_fn(x, y, 128, 128)
            if r != er or g != eg or b != eb:
                errors += 1
    status = "PASS" if errors == 0 else f"FAIL({errors})"
    print(f"  tga_{pattern_name}_128.tga: {status} (16384 pixels)")

print("\nDone!")
