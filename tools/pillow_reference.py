"""Independent RGBA reference with the library's documented PNG normalization.

Pillow clamps 16-bit grayscale when converting to RGBA and discards the low RGB
sample bytes needed for 16-bit tRNS. Read original PNG samples only for these
normalization/transparency cases; filtering uses the PNG specification and zlib.
"""

from io import BytesIO
import struct
import zlib

from PIL import Image


ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8),
         (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))


def png_samples(data, width, height, depth, channels, interlace):
    """Yield original sample tuples without sharing any project decoder code."""
    compressed = bytearray()
    offset = 8
    transparency = None
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if len(payload) != length or offset + length + 12 > len(data):
            raise ValueError("Truncated PNG reference chunk")
        if kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"tRNS":
            transparency = payload
        elif kind == b"IEND":
            break
        offset += length + 12
    try:
        raw = zlib.decompress(compressed)
    except zlib.error as error:
        raise ValueError("Invalid PNG reference zlib stream") from error
    position = 0
    bpp = max(1, (channels * depth + 7) // 8)
    passes = ADAM7 if interlace else ((0, 0, 1, 1),)
    samples = [None] * (width * height)
    for xs, ys, x_step, y_step in passes:
        columns = range(xs, width, x_step)
        if not columns or ys >= height:
            continue
        row_size = (len(columns) * channels * depth + 7) // 8
        previous = bytearray(row_size)
        for y in range(ys, height, y_step):
            if position + row_size + 1 > len(raw):
                raise ValueError("Truncated PNG reference scanline")
            kind = raw[position]
            row = bytearray(raw[position + 1:position + row_size + 1])
            position += row_size + 1
            if kind > 4:
                raise ValueError("Invalid PNG reference filter")
            for index in range(row_size):
                left = row[index - bpp] if index >= bpp else 0
                up = previous[index]
                upper_left = previous[index - bpp] if index >= bpp else 0
                prediction = left + up - upper_left
                neighbors = (left, up, upper_left)
                paeth = min(enumerate(neighbors), key=lambda item: (abs(prediction - item[1]), item[0]))[1]
                row[index] = (row[index] + (0, left, up, (left + up) // 2, paeth)[kind]) & 255
            for px, x in enumerate(columns):
                values = []
                for channel in range(channels):
                    index = px * channels + channel
                    if depth == 16:
                        values.append(int.from_bytes(row[index * 2:index * 2 + 2], "big"))
                    elif depth == 8:
                        values.append(row[index])
                    else:
                        bit = index * depth
                        values.append((row[bit // 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1))
                samples[y * width + x] = tuple(values)
            previous = row
    if position != len(raw) or any(sample is None for sample in samples):
        raise ValueError("Incorrect PNG reference scanline length")
    return samples, transparency


def reference_rgba(data):
    """Decode using Pillow, retaining PNG source precision for conversion/tRNS."""
    with Image.open(BytesIO(data)) as image:
        image.load()
        result = image.convert("RGBA")
        if image.format != "PNG":
            return result
        depth, color = data[24], data[25]
        # Only grayscale and RGB have a color-key tRNS chunk. Other modes use
        # Pillow's independently decoded palette or explicit alpha channels.
        if color not in (0, 2):
            return result
        if not (color == 0 and depth == 16) and "transparency" not in image.info:
            return result
        channels = 1 if color == 0 else 3
        samples, transparency = png_samples(data, image.width, image.height, depth, channels, data[28])
        mask = (1 << depth) - 1
        key = None
        if transparency is not None:
            if len(transparency) != channels * 2:
                raise ValueError("Invalid PNG reference transparency key")
            key = tuple(value & mask for value in struct.unpack(
                ">" + "H" * channels, transparency))
        output = bytearray()
        for sample in samples:
            values = [value >> 8 if depth == 16 else value * 255 // mask for value in sample]
            output.extend(values * 3 if channels == 1 else values)
            output.append(0 if sample == key else 255)
        return Image.frombytes("RGBA", image.size, bytes(output))
