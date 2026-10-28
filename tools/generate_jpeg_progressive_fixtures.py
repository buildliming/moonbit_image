"""Small progressive JPEG fixtures with independent Pillow pixel expectations.

The MoonBit test suite needs no Python or image library at runtime. Regenerate
with Pillow 12.3.0; output contains encoded bytes and RGBA oracle bytes only.
Scan semantics follow ITU-T T.81 Annex G, https://www.w3.org/Graphics/JPEG/itu-t81.pdf.
"""
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageFilter, features
from verify_decoders import original_images


ROOT = Path(__file__).resolve().parent.parent


def literal(data):
    # Bytes has no concatenation operator; a single literal is compact source.
    return 'b"' + ''.join(f'\\x{value:02X}' for value in data) + '"'


def encode(image, **options):
    stream = BytesIO()
    image.save(stream, 'JPEG', quality=88, progressive=True, **options)
    data = stream.getvalue()
    with Image.open(BytesIO(data)) as decoded:
        return data, decoded.convert('RGBA').tobytes(), decoded.size


def segments(data):
    pos = 2
    while pos < len(data):
        begin = pos
        assert data[pos] == 255
        while data[pos] == 255:
            pos += 1
        marker = data[pos]
        pos += 1
        if marker == 0xD9:
            yield marker, begin, pos, pos
            return
        length = int.from_bytes(data[pos:pos + 2], 'big')
        end = pos + length
        yield marker, begin, pos + 2, end
        pos = end
        if marker == 0xDA:
            while pos < len(data):
                if data[pos] != 255:
                    pos += 1
                    continue
                if data[pos + 1] == 0 or 0xD0 <= data[pos + 1] <= 0xD7:
                    pos += 2
                    continue
                break


def changed(data, offset, value):
    return data[:offset] + bytes([value]) + data[offset + 1:]


def spectral_only():
    """Independent tiny spectral-selection encoder, no successive approximation.

    Two grayscale blocks: DC 40, first AC +3 / -3, all other coefficients zero.
    Complete AC bands avoid optional libjpeg preview smoothing in the oracle.
    """
    def segment(marker, payload):
        return b'\xff' + bytes([marker]) + (len(payload) + 2).to_bytes(2, 'big') + payload

    def entropy(bits):
        bits += '1' * (-len(bits) % 8)
        return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)).replace(b'\xff', b'\xff\x00')

    dqt = segment(0xDB, bytes([0]) + bytes([1]) * 64)
    sof = segment(0xC2, bytes([8, 0, 8, 0, 16, 1, 1, 0x11, 0]))
    # DC: category 6 code 0, category 0 code 10. AC: size 2 code 0, EOB code 10.
    counts = bytes([1, 1] + [0] * 14)
    dht = segment(0xC4, bytes([0]) + counts + bytes([6, 0]) + bytes([0x10]) + counts + bytes([2, 0]))
    dc = segment(0xDA, bytes([1, 1, 0, 0, 0, 0])) + entropy('0' + '101000' + '10')
    ac = segment(0xDA, bytes([1, 1, 0, 1, 63, 0])) + entropy('0' + '11' + '10' + '0' + '00' + '10')
    return b'\xff\xd8' + dqt + dht + sof + dc + ac + b'\xff\xd9'


def generate():
    cases = {}
    pattern = Image.new('RGB', (19, 17))
    pattern.putdata([((x * 19 + y * 13) % 256, (x * 7 + y * 29) % 256,
                      (x * 31 + y * 3) % 256) for y in range(17) for x in range(19)])
    for sampling in range(3):
        cases[f'color_sampling_{sampling}'] = encode(pattern, subsampling=sampling)
        cases[f'restarts_sampling_{sampling}'] = encode(
            pattern, subsampling=sampling, restart_marker_blocks=1)
    cases['gray'] = encode(pattern.convert('L'))
    cases['gray_restart'] = encode(pattern.convert('L'), restart_marker_blocks=2)
    cases['gray_high_frequency'] = encode(Image.frombytes(
        'L', (17, 9), bytes(255 * ((x + y) % 2) for y in range(9) for x in range(17))))
    for width in (1, 3, 4):
        cases[f'narrow_{width}'] = encode(pattern.resize((width, 9)), subsampling=2)
    cases['eob_runs'] = encode(Image.new('RGB', (97, 17), (100, 100, 100)), subsampling=2)
    # Reuse tracked photographic bytes; fresh checkouts need no ignored images.
    _, photo_bytes, _ = next(original_images(None))
    with Image.open(BytesIO(photo_bytes)) as photo:
        photo = photo.convert('RGB').resize((31, 23))
    cases['photograph'] = encode(photo, subsampling=2)
    cases['photograph_gaussian_blur'] = encode(photo.filter(ImageFilter.GaussianBlur(2)), subsampling=1)
    spectral = spectral_only()
    with Image.open(BytesIO(spectral)) as decoded:
        cases['spectral_selection_only'] = (spectral, decoded.convert('RGBA').tobytes(), decoded.size)
    # T.81 B.2.3 permits 0..3 in both selector fields for progressive scans.
    # Define table 3 as well, so unused nonzero fields cannot refer to missing tables.
    dht_start, dht_end = next((start, end) for marker, _, start, end in segments(spectral)
                              if marker == 0xC4)
    extra_tables = bytearray(spectral[dht_start:dht_end])
    table = 0
    while table < len(extra_tables):
        extra_tables[table] += 3
        table += 17 + sum(extra_tables[table + 1:table + 17])
    table_segment = b'\xff\xc4' + (len(extra_tables) + 2).to_bytes(2, 'big') + extra_tables
    extended = spectral[:2] + table_segment + spectral[2:]
    for unused in ('dc', 'ac'):
        selected = bytearray(extended)
        for marker, _, start, end in segments(extended):
            if marker == 0xDA:
                if unused == 'dc' and extended[end - 3] > 0:
                    selected[start + 2] |= 0x30
                elif unused == 'ac' and extended[end - 3] == 0:
                    selected[start + 2] |= 0x03
        with Image.open(BytesIO(selected)) as decoded:
            expected = decoded.convert('RGBA').tobytes()
            assert expected == cases['spectral_selection_only'][1]
        cases[f'unused_{unused}_selector'] = (bytes(selected), expected, (16, 8))

    data, _, _ = cases['color_sampling_2']
    scan_headers = [(begin, start, end) for marker, begin, start, end in segments(data)
                    if marker == 0xDA]
    first_begin, first_start, first_end = scan_headers[0]
    # A DC-only progressive image at EOI is valid: omitted AC coefficients are 0.
    second_begin = next(begin for marker, begin, _, _ in segments(data) if begin > first_end)
    # Flat content avoids libjpeg's optional DC-neighbor smoothing of previews.
    flat_data = cases['eob_runs'][0]
    flat_scan_end = next(end for marker, _, _, end in segments(flat_data) if marker == 0xDA)
    flat_second = next(begin for _, begin, _, _ in segments(flat_data) if begin > flat_scan_end)
    dc_only = flat_data[:flat_second] + b'\xff\xd9'
    with Image.open(BytesIO(dc_only)) as decoded:
        cases['dc_only_preview'] = (dc_only, decoded.convert('RGBA').tobytes(), decoded.size)
    # DHT is legal before SOF2. Keep all tables as they were on the first scan.
    before_scan = list(segments(data[:first_begin] + b'\xff\xd9'))[:-1]
    header = data[:2] + b''.join(data[begin:end] for marker, begin, _, end in before_scan if marker == 0xC4)
    header += b''.join(data[begin:end] for marker, begin, _, end in before_scan if marker != 0xC4)
    cases['tables_before_frame'] = (header + data[first_begin:], cases['color_sampling_2'][1], (19, 17))
    # Progressive scans may select any of the four Huffman table slots.
    slots = bytearray(data)
    for marker, _, start, end in segments(data):
        if marker == 0xC4:
            table = start
            while table < end:
                slots[table] += 2
                table += 17 + sum(data[table + 1:table + 17])
        elif marker == 0xDA:
            first = data[end - 3]
            high = data[end - 1] >> 4
            for component in range(data[start]):
                index = start + 2 + component * 2
                if first > 0:
                    slots[index] += 2
                elif high == 0:
                    slots[index] += 0x20
    cases['four_huffman_table_slots'] = (bytes(slots), cases['color_sampling_2'][1], (19, 17))

    invalid = {
        'dc_band_end': changed(data, first_end - 2, 1),
        'ac_multiple_components': changed(data, first_end - 3, 1),
        'approximation_overflow': changed(data, first_end - 1, 14),
        'refinement_without_first': changed(data, first_end - 1, 0x10),
        'duplicate_component': changed(data, first_start + 3, data[first_start + 1]),
        'unknown_component': changed(data, first_start + 1, 99),
        'missing_eoi': data[:-2],
        'missing_component_dc': data[:first_begin] + b'\xff\xd9',
        'entropy_padding': data[:second_begin] + b'\x00\xff\xd9',
    }
    for _, start, end in scan_headers[1:]:
        if data[end - 3] > 0 and data[end - 1] >> 4 == 0:
            invalid['ac_before_dc'] = data[:first_begin] + data[second_begin:]
            invalid['spectral_band_out_of_range'] = changed(data, end - 2, 64)
            invalid['reversed_spectral_band'] = changed(data, end - 3, data[end - 2] + 1)
            break
    for _, start, end in scan_headers[1:]:
        if data[end - 1] >> 4 != 0:
            invalid['skipped_refinement_level'] = changed(data, end - 1, 0x31)
            invalid['duplicate_initial_band'] = changed(data, end - 1, 0)
            break
    # 8192 squared fits a 3-byte image but its coefficient working set does not.
    for marker, _, start, _ in segments(data):
        if marker == 0xC2:
            invalid['working_set_limit'] = data[:start + 1] + b'\x20\x00\x20\x00' + data[start + 5:]
    restart = cases['restarts_sampling_2'][0]
    restart_offset = next(i for i in range(len(restart) - 1) if restart[i:i + 2] == b'\xff\xd0')
    invalid['restart_sequence'] = changed(restart, restart_offset + 1, 0xD2)
    invalid['restart_missing'] = restart[:restart_offset] + restart[restart_offset + 2:]
    # Replace first AC entropy with EOB run 3 while only two blocks remain.
    # EOB1 table (symbol 0x10, code 0), followed by run extension bit 1.
    spectral_ac = [(begin, start, end) for marker, begin, start, end in segments(spectral)
                   if marker == 0xDA][-1]
    eob_table = b'\xff\xc4\x00\x14\x10\x01' + bytes(15) + b'\x10'
    begin, _, end = spectral_ac
    invalid['eob_exceeds_scan'] = spectral[:begin] + eob_table + spectral[begin:end] + b'\x7f\xff\xd9'
    changed_quantization = b'\xff\xdb\x00\x43\x00' + bytes([2]) * 64
    invalid['quantization_changes_between_scans'] = (
        spectral[:begin] + changed_quantization + spectral[begin:])
    repeated_quantization = b'\xff\xdb\x00\x43\x00' + bytes([1]) * 64
    cases['repeated_identical_quantization'] = (
        spectral[:begin] + repeated_quantization + spectral[begin:],
        cases['spectral_selection_only'][1], (16, 8))
    sof_begin = next(begin for marker, begin, _, _ in segments(spectral) if marker == 0xC2)
    eob_before_frame = (spectral[:sof_begin] + eob_table + spectral[sof_begin:end]
                        + b'\x3f\xff\xd9')
    with Image.open(BytesIO(eob_before_frame)) as decoded:
        cases['eob_table_before_frame'] = (eob_before_frame, decoded.convert('RGBA').tobytes(), decoded.size)

    source = (f'// Generated by tools/generate_jpeg_progressive_fixtures.py.\n'
              f'// Oracle: Pillow {Image.__version__}, libjpeg {features.version("jpg")}; tolerance 3.\n'
              '// DC/AC first/refinement scans, restarts, actual photo and blurred photo.\n')
    for name, (encoded, expected, (width, height)) in cases.items():
        source += f'''\n///|
test "jpeg_progressive_{name}" {{
  let data = {literal(encoded)}
  let image = @image.decode_jpeg(data)
  assert_eq(@image.jpeg_dimensions(data), ({width}, {height}))
  assert_eq((image.width, image.height), ({width}, {height}))
  photo_reference_compare(image.to_rgba8().data, {literal(expected)}, 3)
}}
'''
    for name, encoded in invalid.items():
        source += f'''\n///|
test "jpeg_progressive_reject_{name}" {{
  jpeg_regression_reject({literal(encoded)})
}}
'''
    source += f'''\n///|
test "jpeg_progressive_every_truncated_prefix" {{
  let data = {literal(cases['gray'][0])}
  for length = 0; length < data.length(); length = length + 1 {{
    jpeg_regression_reject(data[:length].to_owned())
  }}
}}
'''
    (ROOT / 'jpeg_progressive_test.mbt').write_text(source, encoding='utf-8')
    print(f'Wrote {len(cases)} valid progressive and {len(invalid)} invalid cases plus truncations')


if __name__ == '__main__':
    generate()
