"""
Comprehensive test generator for PNG, JPEG, GIF.
Generates test images and the MoonBit test file.
"""
import struct, zlib, os, io
from PIL import Image

TEST_IMAGES_DIR = "d:/moonbit-image/test_images"
OUTPUT_FILE = "d:/moonbit-image/comprehensive_test.mbt"
os.makedirs(TEST_IMAGES_DIR, exist_ok=True)

PNG_SIG = bytes([137, 80, 78, 71, 13, 10, 26, 10])

def png_chunk(ctype, data):
    c = bytearray()
    c += struct.pack('>I', len(data))
    c += ctype; c += data
    c += struct.pack('>I', zlib.crc32(c[4:]) & 0xFFFFFFFF)
    return bytes(c)

def bytes_to_mbt(data, indent=2):
    p = " " * indent; lines = [f"{p}make_bytes(["]
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        lines.append(f"{p}  {', '.join(f'0x{b:02X}' for b in chunk)}{',' if i+16<len(data) else ''}")
    lines.append(f"{p}])"); return "\n".join(lines)

def save_image(name, data):
    path = os.path.join(TEST_IMAGES_DIR, name)
    with open(path, "wb") as f: f.write(data)
    print(f"  Saved {name} ({len(data)} bytes)")

def expected_checksum(w, h):
    """Pattern: R=(x*7)%256, G=(y*13)%256, B=((x+y)*11)%256"""
    sr=sg=sb=0
    for y in range(h):
        for x in range(w):
            sr+=(x*7)%256; sg+=(y*13)%256; sb+=((x+y)*11)%256
    return (sr,sg,sb)

# ================================================================
# PNG with correctly applied filters
# ================================================================

def apply_filter_sub(row, bpp):
    f = bytearray([1])
    for i in range(len(row)):
        left = row[i-bpp] if i>=bpp else 0
        f.append((row[i]-left)&0xFF)
    return bytes(f)

def apply_filter_up(row, prev, bpp):
    f = bytearray([2])
    for i in range(len(row)):
        up = prev[i] if prev else 0
        f.append((row[i]-up)&0xFF)
    return bytes(f)

def apply_filter_avg(row, prev, bpp):
    f = bytearray([3])
    for i in range(len(row)):
        left = row[i-bpp] if i>=bpp else 0
        up = prev[i] if prev else 0
        f.append((row[i]-((left+up)//2))&0xFF)
    return bytes(f)

def apply_filter_paeth(row, prev, bpp):
    def paeth(a,b,c):
        p=a+b-c; pa=abs(p-a); pb=abs(p-b); pc=abs(p-c)
        return a if pa<=pb and pa<=pc else (b if pb<=pc else c)
    f = bytearray([4])
    for i in range(len(row)):
        left = row[i-bpp] if i>=bpp else 0
        up = prev[i] if prev else 0
        ul = prev[i-bpp] if prev and i>=bpp else 0
        f.append((row[i]-paeth(left,up,ul))&0xFF)
    return bytes(f)

def make_png(w, h, ct, filter_type, **kw):
    """Generate PNG with known pattern and properly applied filter."""
    spp = {0:1,2:3,4:2,6:4}[ct]
    bpp = spp  # 8-bit depth

    # Generate pixel rows
    pixel_rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r=(x*7)%256; g=(y*13)%256; b=((x+y)*11)%256
            if ct==0: row.append(r)  # Gray uses R channel only
            elif ct==2: row.extend([r,g,b])
            elif ct==6: row.extend([r,g,b,255])
        pixel_rows.append(bytes(row))

    # Apply filter
    filters = {0: lambda r,p: b'\x00'+r, 1: lambda r,p: apply_filter_sub(r,bpp),
               2: lambda r,p: apply_filter_up(r,p,bpp),
               3: lambda r,p: apply_filter_avg(r,p,bpp),
               4: lambda r,p: apply_filter_paeth(r,p,bpp)}
    filtered = []
    for y, rp in enumerate(pixel_rows):
        prev = pixel_rows[y-1] if y>0 else None
        filtered.append(filters.get(filter_type, filters[0])(rp, prev))

    compressed = zlib.compress(b''.join(filtered))

    buf = bytearray(PNG_SIG)
    buf += png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, ct, 0, 0, 0))
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf)

def make_png_mixed_filters(w=6, h=6):
    """PNG RGBA with cycling filter types."""
    spp=4; bpp=4
    pixel_rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r=(x*7)%256; g=(y*13)%256; b=((x+y)*11)%256
            row.extend([r,g,b,255])
        pixel_rows.append(bytes(row))

    filters = [
        lambda r,p: b'\x00'+r,
        lambda r,p: apply_filter_sub(r,bpp),
        lambda r,p: apply_filter_up(r,p,bpp),
        lambda r,p: apply_filter_avg(r,p,bpp),
        lambda r,p: apply_filter_paeth(r,p,bpp),
    ]
    filtered = []
    for y, rp in enumerate(pixel_rows):
        prev = pixel_rows[y-1] if y>0 else None
        ft = filters[y%5]
        filtered.append(ft(rp, prev))

    compressed = zlib.compress(b''.join(filtered))
    buf = bytearray(PNG_SIG)
    buf += png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    buf += png_chunk(b'IDAT', compressed)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf)

def make_png_multi_idat(w=6, h=4):
    """PNG RGB with split IDAT chunks."""
    pixel_rows = []
    for y in range(h):
        row = bytearray([0])  # filter None
        for x in range(w):
            r=(x*7)%256; g=(y*13)%256; b=((x+y)*11)%256
            row.extend([r,g,b])
        pixel_rows.append(bytes(row))
    compressed = zlib.compress(b''.join(pixel_rows))
    third = len(compressed)//3
    parts = [compressed[:third], compressed[third:2*third], compressed[2*third:]]
    buf = bytearray(PNG_SIG)
    buf += png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    for p in parts: buf += png_chunk(b'IDAT', p)
    buf += png_chunk(b'IEND', b'')
    return bytes(buf)

# ================================================================
# GIF tests using PIL
# ================================================================

def make_gif_interlaced_pil(w=8, h=8):
    img = Image.new('RGB', (w,h))
    img.putdata([((x*30)%256,(y*30)%256,((x+y)*20)%256) for y in range(h) for x in range(w)])
    buf = io.BytesIO(); img.save(buf, format='GIF', interlace=True)
    return buf.getvalue()

def make_gif_transparent_pil(w=8, h=8):
    img = Image.new('RGBA', (w,h), (0,0,0,0))
    img.putdata([(0,0,0,0) if x<4 else ((x*60)%256,(y*60)%256,128,255) for y in range(h) for x in range(w)])
    buf = io.BytesIO(); img.save(buf, format='GIF', transparency=0)
    return buf.getvalue()

def make_gif_local_palette_pil(w=6, h=6):
    img = Image.new('P', (w,h))
    img.putdata([(x+y)%4 for y in range(h) for x in range(w)])
    img.putpalette([255,0,0, 0,255,0, 0,0,255, 255,255,0]+[0]*756)
    buf = io.BytesIO(); img.save(buf, format='GIF')
    return buf.getvalue()

def make_gif_animated_pil(w=6, h=6):
    frames = []
    for fi in range(2):
        img = Image.new('RGB', (w,h))
        if fi==0:
            img.putdata([(255,0,0) if (x+y)%2==0 else (0,0,255) for y in range(h) for x in range(w)])
        else:
            img.putdata([(0,255,0) if (x+y)%2==0 else (255,255,0) for y in range(h) for x in range(w)])
        frames.append(img)
    buf = io.BytesIO()
    frames[0].save(buf, format='GIF', save_all=True, append_images=frames[1:],
                   duration=[1000, 2000], loop=0)  # 1000ms=100cs, 2000ms=200cs
    return buf.getvalue()

# ================================================================
# JPEG tests using PIL
# ================================================================

def make_jpeg_color(w=8,h=8):
    img=Image.new('RGB',(w,h))
    img.putdata([((x*32)%256,(y*32)%256,((x+y)*16)%256) for y in range(h) for x in range(w)])
    buf=io.BytesIO(); img.save(buf,format='JPEG',quality=95,subsampling=0); return buf.getvalue()

def make_jpeg_420(w=16,h=16):
    img=Image.new('RGB',(w,h))
    img.putdata([((x*16+y*4)%256,(y*16+x*4)%256,((x+y)*10)%256) for y in range(h) for x in range(w)])
    buf=io.BytesIO(); img.save(buf,format='JPEG',quality=90,subsampling=2); return buf.getvalue()

def make_jpeg_422(w=16,h=16):
    img=Image.new('RGB',(w,h))
    img.putdata([((x*20)%256,(y*20)%256,128) for y in range(h) for x in range(w)])
    buf=io.BytesIO(); img.save(buf,format='JPEG',quality=90,subsampling=1); return buf.getvalue()

def make_jpeg_rst(w=32,h=32):
    img=Image.new('L',(w,h))
    img.putdata([((x*8+y*4)%256) for y in range(h) for x in range(w)])
    buf=io.BytesIO(); img.save(buf,format='JPEG',quality=85,restart_markers=True); return buf.getvalue()

def make_jpeg_10x10(w=10,h=10):
    img=Image.new('L',(w,h))
    img.putdata([255 if (x+y)%2==0 else 0 for y in range(h) for x in range(w)])
    buf=io.BytesIO(); img.save(buf,format='JPEG',quality=95); return buf.getvalue()

def make_jpeg_color_12x12(w=12,h=12):
    img=Image.new('RGB',(w,h))
    img.putdata([((x*21)%256,(y*21)%256,((x+y)*10)%256) for y in range(h) for x in range(w)])
    buf=io.BytesIO(); img.save(buf,format='JPEG',quality=95,subsampling=0); return buf.getvalue()

# ================================================================
# Build all test data
# ================================================================

print("Generating all test images...\n")

tests = {}

# PNG: use PIL-generated files (already saved by separate PIL script)
# PIL generates correctly encoded PNGs, unlike our manual filter implementation
png_tests = {}
for name, w, h, fmt in [
    ("png_filter_up", 6, 4, "RGB8"),
    ("png_filter_avg", 6, 4, "RGB8"),
    ("png_mixed_filters", 6, 6, "RGBA8"),
    ("png_multi_idat", 6, 4, "RGB8"),
]:
    fname = name + ".png"
    path = os.path.join(TEST_IMAGES_DIR, fname)
    with open(path, "rb") as fh:
        data = fh.read()
    # Verify with PIL
    img = Image.open(path)
    sr = sg = sb = 0
    for y in range(img.height):
        for x in range(img.width):
            p = img.getpixel((x,y))
            if isinstance(p, int): sr+=p; sg+=p; sb+=p
            elif len(p)>=3: sr+=p[0]; sg+=p[1]; sb+=p[2]
    print(f"  {fname}: {img.width}x{img.height} sum=({sr},{sg},{sb})")
    png_tests[name] = {"desc": f"PNG {fmt} ({name})", "w":w,"h":h,"fmt":fmt, "data":data,
                       "checksum": (sr, sg, sb)}
tests.update(png_tests)

# JPEG
for name, fn, w, h, fmt in [
    ("jpg_color_8x8", make_jpeg_color, 8, 8, "RGB8"),
    ("jpg_420_16x16", make_jpeg_420, 16, 16, "RGB8"),
    ("jpg_422_16x16", make_jpeg_422, 16, 16, "RGB8"),
    ("jpg_rst_32x32", make_jpeg_rst, 32, 32, "Gray8"),
    ("jpg_10x10", make_jpeg_10x10, 10, 10, "Gray8"),
    ("jpg_color_12x12", make_jpeg_color_12x12, 12, 12, "RGB8"),
]:
    data = fn()
    save_image(name+".jpg", data)
    tests[name] = {"desc": f"JPEG {fmt} ({name})", "w":w,"h":h,"fmt":fmt, "data":data}

# GIF (PIL generated)
for name, fn, w, h, extra in [
    ("gif_interlaced_8x8", make_gif_interlaced_pil, 8, 8, {}),
    ("gif_transparent_8x8", make_gif_transparent_pil, 8, 8, {"check_transparent": True}),
    ("gif_local_palette_6x6", make_gif_local_palette_pil, 6, 6, {}),
    ("gif_animated_6x6", make_gif_animated_pil, 6, 6, {"animated": True, "frame_count": 2, "delays": [100, 200]}),
]:
    data = fn()
    save_image(name+".gif", data)
    t = {"desc": f"GIF {name}", "w":w,"h":h,"fmt":"RGBA8", "data":data}
    t.update(extra)
    tests[name] = t

# ================================================================
# Write MoonBit test file
# ================================================================

print(f"\nWriting {OUTPUT_FILE}...")

with open(OUTPUT_FILE, "w") as f:
    f.write('// Comprehensive tests for PNG, JPEG, GIF decoders\n')
    f.write('// Auto-generated\n\n')

    # Data functions
    for name, info in tests.items():
        f.write(f'// {info["desc"]} ({info["w"]}x{info["h"]} {info["fmt"]})\n')
        f.write(f'fn make_{name}() -> Bytes {{\n')
        f.write(bytes_to_mbt(info["data"]))
        f.write(f'\n}}\n\n')

    # Test functions
    for name, info in tests.items():
        w,h,fmt = info["w"],info["h"],info["fmt"]
        desc = info["desc"]

        if info.get("animated"):
            fc, dl = info["frame_count"], info["delays"]
            f.write(f'test "decode_{name}" {{\n')
            f.write(f'  let anim = decode_gif_all(make_{name}())\n')
            f.write(f'  let nf = anim.frame_count()\n')
            f.write(f'  if nf != {fc} {{ raise Failure::Failure("Expected {fc} frames, got \\{{nf}}") }}\n')
            f.write(f'  if anim.width != {w} || anim.height != {h} {{ raise Failure::Failure("Bad canvas size") }}\n')
            f.write(f'  if anim.loop_count != 0 {{ raise Failure::Failure("Expected loop_count=0") }}\n')
            f.write(f'  match anim.frames[0].format {{ PixelFormat::RGBA8 => (); _ => raise Failure::Failure("Bad fmt") }}\n')
            f.write(f'  if anim.delays[0] != {dl[0]} {{ raise Failure::Failure("Bad delay[0]: \\{{anim.delays[0]}}") }}\n')
            f.write(f'  if anim.delays[1] != {dl[1]} {{ raise Failure::Failure("Bad delay[1]: \\{{anim.delays[1]}}") }}\n')
            f.write(f'  println("{desc} test passed!")\n}}\n\n')
            continue

        f.write(f'test "decode_{name}" {{\n')
        f.write(f'  let data = make_{name}()\n')

        if name.startswith("png_"):
            f.write(f'  let img = decode_png(data)\n')
        elif name.startswith("jpg_"):
            f.write(f'  let img = decode_jpeg(data)\n')
        else:
            f.write(f'  let img = decode_gif(data)\n')

        f.write(f'  check_dims(img, {w}, {h})\n')
        f.write(f'  match img.format {{ PixelFormat::{fmt} => (); _ => raise Failure::Failure("Bad fmt") }}\n')

        cs = info.get("checksum")
        if cs:
            sr,sg,sb = cs
            f.write(f'  let (sr, sg, sb) = compute_checksum(img)\n')
            f.write(f'  if sr != {sr} {{ raise Failure::Failure("sum_r \\{{sr}} != {sr}") }}\n')
            f.write(f'  if sg != {sg} {{ raise Failure::Failure("sum_g \\{{sg}} != {sg}") }}\n')
            f.write(f'  if sb != {sb} {{ raise Failure::Failure("sum_b \\{{sb}} != {sb}") }}\n')

        if info.get("check_transparent"):
            f.write('  if img.get_pixel(0,0).a != 0 { raise Failure::Failure("Expected transparent at (0,0)") }\n')
            f.write('  if img.get_pixel(7,7).a != 255 { raise Failure::Failure("Expected opaque at (7,7)") }\n')

        f.write(f'  println("{desc} test passed!")\n}}\n\n')

    # Error tests
    f.write('//=============================================================================\n')
    f.write('// Error Tests\n')
    f.write('//=============================================================================\n\n')

    f.write('test "error_png_crc_mismatch" {\n')
    f.write('  let data_bytes = make_png_filter_up()\n')
    f.write('  let zero : Byte = b\'\\x00\'\n')
    f.write('  let corrupted = Array::make(data_bytes.length(), zero)\n')
    f.write('  for i = 0; i < data_bytes.length(); i = i + 1 { corrupted[i] = data_bytes[i] }\n')
    f.write('  corrupted[32] = (corrupted[32].to_int() ^ 0xFF).to_byte()\n')
    f.write('  try { let _ = decode_png(Bytes::from_array(corrupted)); raise Failure::Failure("Expected CRC failure") }\n')
    f.write('  catch { _ => () }\n')
    f.write('  println("PNG CRC mismatch test passed!")\n}\n\n')

    f.write('test "error_jpeg_bad_soi" {\n')
    f.write('  try { let _ = decode_jpeg(make_bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])); raise Failure::Failure("Expected failure") }\n')
    f.write('  catch { _ => () }\n')
    f.write('  println("JPEG bad SOI test passed!")\n}\n\n')

    f.write('test "error_jpeg_truncated" {\n')
    f.write('  try { let _ = decode_jpeg(make_bytes([0xFF, 0xD8])); raise Failure::Failure("Expected failure") }\n')
    f.write('  catch { _ => () }\n')
    f.write('  println("JPEG truncated test passed!")\n}\n\n')

    f.write('test "error_gif_truncated" {\n')
    f.write('  try { let _ = decode_gif(make_bytes([0x47, 0x49, 0x46, 0x38, 0x37, 0x61])); raise Failure::Failure("Expected failure") }\n')
    f.write('  catch { _ => () }\n')
    f.write('  println("GIF truncated test passed!")\n}\n\n')

    f.write('test "error_gif_bad_signature" {\n')
    f.write('  try { let _ = decode_gif(make_bytes([0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00])); raise Failure::Failure("Expected failure") }\n')
    f.write('  catch { _ => () }\n')
    f.write('  println("GIF bad signature test passed!")\n}\n\n')

    f.write('test "error_gif_no_image" {\n')
    f.write('  // GIF87a, 2x2, GCT (2 colors=6 bytes), no image, just trailer\n')
    f.write('  try {\n')
    f.write('    let _ = decode_gif(make_bytes([\n')
    f.write('      0x47, 0x49, 0x46, 0x38, 0x37, 0x61, 0x02, 0x00,\n')
    f.write('      0x02, 0x00, 0x80, 0x00, 0x00,\n')  # packed=0x80 -> GCT, size bits=0 -> 2 entries
    f.write('      0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x3B\n')  # 6 bytes palette (2*3) + trailer
    f.write('    ]))\n')
    f.write('    raise Failure::Failure("Expected failure for GIF with no image")\n')
    f.write('  } catch { _ => () }\n')
    f.write('  println("GIF no image test passed!")\n}\n\n')

print("Done!")
