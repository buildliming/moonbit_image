import struct, os

def make_gif(w, h, pixels_flat):
    buf = bytearray(b'GIF87a')
    buf += struct.pack('<HH', w, h)
    buf += struct.pack('<B', 0xF7)
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0)
    unique = sorted(set(pixels_flat))
    palette = list(unique) + [(0,0,0)] * (256 - len(unique))
    for r,g,b in palette: buf += struct.pack('BBB', r, g, b)
    buf += struct.pack('<B', 0x2C) + struct.pack('<HH', 0, 0) + struct.pack('<HH', w, h) + struct.pack('<B', 0x00)
    min_code_size = 8
    clear_code, eoi_code = 256, 257
    indices = [unique.index(p) for p in pixels_flat]
    # LZW encoder
    table_prefix = [-1]*4096
    table_suffix = list(range(4096))
    next_code = 258
    code_size = 9
    max_code = (1 << code_size) - 1
    out_bits = []
    def wc(code, bits):
        for i in range(bits): out_bits.append((code >> i) & 1)
    wc(clear_code, code_size)
    cur = indices[0]
    for idx in indices[1:]:
        found = -1
        for c in range(258, next_code):
            if table_prefix[c] == cur and table_suffix[c] == idx:
                found = c; break
        if found >= 0:
            cur = found
        else:
            wc(cur, code_size)
            if next_code < 4096:
                table_prefix[next_code] = cur
                table_suffix[next_code] = idx
                next_code += 1
                if next_code > max_code and code_size < 12:
                    code_size += 1
                    max_code = (1 << code_size) - 1
            cur = idx
    wc(cur, code_size)
    wc(eoi_code, code_size)
    while len(out_bits) % 8: out_bits.append(0)
    data_bytes = bytearray()
    for i in range(0, len(out_bits), 8):
        byte = 0
        for j in range(8): byte |= out_bits[i+j] << j
        data_bytes.append(byte)
    buf += struct.pack('<B', min_code_size)
    pos = 0
    while pos < len(data_bytes):
        blen = min(255, len(data_bytes)-pos)
        buf += struct.pack('<B', blen) + data_bytes[pos:pos+blen]
        pos += blen
    buf += struct.pack('<B', 0)
    buf += struct.pack('<B', 0x3B)
    return bytes(buf)

os.makedirs('test_images', exist_ok=True)

# Test 1: 4x4 red/blue checker
pixels = [(255,0,0) if (x+y)%2==0 else (0,0,255) for y in range(4) for x in range(4)]
gif = make_gif(4, 4, pixels)
with open('test_images/test_gif.gif', 'wb') as f: f.write(gif)
print(f'Generated test_gif.gif: {len(gif)} bytes')

# Test 2: 8x8 grayscale checker
pixels2 = [(v,v,v) for y in range(8) for x in range(8)
           for v in [255 if ((x//2)+(y//2))%2==0 else 0]][:64]
# Actually let me be more careful:
pixels2 = []
for y in range(8):
    for x in range(8):
        v = 255 if ((x//2)+(y//2))%2==0 else 0
        pixels2.append((v,v,v))
gif2 = make_gif(8, 8, pixels2)
with open('test_images/test_gif_8x8.gif', 'wb') as f: f.write(gif2)
print(f'Generated test_gif_8x8.gif: {len(gif2)} bytes')

# Print MoonBit hex for the 4x4 GIF
print('\n// GIF 4x4 test data:')
for i in range(0, len(gif), 16):
    chunk = gif[i:i+16]
    hx = ', '.join(f'0x{b:02X}' for b in chunk)
    print(f'    {hx},')
