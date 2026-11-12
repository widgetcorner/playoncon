#!/usr/bin/env python3
"""Strip an opaque simulator PNG's alpha without changing its RGB samples.

The standard-library codec keeps the screenshot's color profile and metadata.
It intentionally accepts only the 8-bit, non-interlaced RGB/RGBA PNGs produced
by simctl. No resizing, color conversion, or image compositing takes place.
"""

import argparse
import json
from pathlib import Path
import struct
import sys
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COLOR_METADATA = {
    b"cHRM", b"gAMA", b"iCCP", b"sBIT", b"sRGB", b"cICP", b"mDCV",
    b"cLLI", b"bKGD", b"pHYs", b"eXIf", b"tEXt", b"zTXt", b"iTXt",
}
BRIGHT_COMPONENTS = bytes(0 if value <= 16 else 1 for value in range(256))


def png_chunk(kind, data):
    checksum = zlib.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)


def read_png(path):
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Source is not a PNG.")
    chunks = []
    position = len(PNG_SIGNATURE)
    while position < len(data):
        if position + 12 > len(data):
            raise ValueError("Truncated PNG chunk.")
        size = struct.unpack_from(">I", data, position)[0]
        end = position + 12 + size
        if end > len(data):
            raise ValueError("Truncated PNG chunk data.")
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + size]
        checksum = struct.unpack_from(">I", data, position + 8 + size)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != checksum:
            raise ValueError(f"Invalid {kind.decode('ascii')} chunk checksum.")
        chunks.append((kind, payload))
        position = end
        if kind == b"IEND":
            break
    if not chunks or chunks[0][0] != b"IHDR" or chunks[-1][0] != b"IEND":
        raise ValueError("PNG is missing its header or end marker.")
    if position != len(data):
        raise ValueError("Unexpected data after the PNG end marker.")
    width, height, depth, color, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", chunks[0][1]
    )
    if depth != 8 or color not in (2, 6) or compression or filtering or interlace:
        raise ValueError("Expected an 8-bit non-interlaced RGB or RGBA simulator PNG.")
    if any(kind == b"tRNS" for kind, _ in chunks):
        raise ValueError("Source has a transparency key; capture with --mask=ignored.")
    compressed = b"".join(payload for kind, payload in chunks if kind == b"IDAT")
    raw = zlib.decompress(compressed)
    channels = 4 if color == 6 else 3
    if len(raw) != height * (width * channels + 1):
        raise ValueError("Decoded PNG length does not match its dimensions.")
    return width, height, channels, chunks, raw


def paeth(left, above, upper_left):
    prediction = left + above - upper_left
    left_distance = abs(prediction - left)
    above_distance = abs(prediction - above)
    corner_distance = abs(prediction - upper_left)
    if left_distance <= above_distance and left_distance <= corner_distance:
        return left
    if above_distance <= corner_distance:
        return above
    return upper_left


def rgb_rows(width, height, channels, raw):
    stride = width * channels
    previous = bytearray(stride)
    for row_index in range(height):
        start = row_index * (stride + 1)
        filtering = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        if filtering == 1:
            for index in range(channels, stride):
                row[index] = (row[index] + row[index - channels]) & 255
        elif filtering == 2:
            for index in range(stride):
                row[index] = (row[index] + previous[index]) & 255
        elif filtering == 3:
            for index in range(stride):
                left = row[index - channels] if index >= channels else 0
                row[index] = (row[index] + (left + previous[index]) // 2) & 255
        elif filtering == 4:
            for index in range(stride):
                left = row[index - channels] if index >= channels else 0
                upper_left = previous[index - channels] if index >= channels else 0
                row[index] = (row[index] + paeth(left, previous[index], upper_left)) & 255
        elif filtering != 0:
            raise ValueError(f"Unsupported PNG row filter: {filtering}.")
        previous = row
        if channels == 4:
            if row[3::4].count(255) != width:
                raise ValueError("Source has transparent pixels; capture with --mask=ignored.")
            rgb = bytearray(width * 3)
            rgb[0::3], rgb[1::3], rgb[2::3] = row[0::4], row[1::4], row[2::4]
            yield rgb
        else:
            yield row


def encode_opaque(source, destination, marker):
    width, height, channels, chunks, raw = read_png(source)
    expected_width, expected_height = marker.get("width"), marker.get("height")
    if (width, height) != (expected_width, expected_height):
        raise ValueError(
            f"Screenshot is {width}×{height}; ready app viewport is "
            f"{expected_width}×{expected_height}. Check simulator orientation and POC_CAPTURE_DISPLAY."
        )
    compressed = bytearray()
    compressor = zlib.compressobj(level=6)
    bright_components = 0
    distinct_components = set()
    for rgb in rgb_rows(width, height, channels, raw):
        bright_components += rgb.translate(BRIGHT_COMPONENTS).count(1)
        if len(distinct_components) < 16:
            distinct_components.update(rgb)
        compressed.extend(compressor.compress(b"\x00" + rgb))
    compressed.extend(compressor.flush())
    if bright_components <= width * height * 3 * 0.005 or len(distinct_components) < 16:
        raise ValueError("Screenshot is blank or nearly black; select the active simulator display.")
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    result = bytearray(PNG_SIGNATURE + png_chunk(b"IHDR", header))
    for kind, payload in chunks:
        if kind in COLOR_METADATA:
            if kind == b"sBIT" and channels == 4:
                payload = payload[:3]
            result.extend(png_chunk(kind, payload))
    result.extend(png_chunk(b"IDAT", compressed))
    result.extend(png_chunk(b"IEND", b""))
    if result[24:26] != b"\x08\x02":
        raise ValueError("Output is not an 8-bit RGB PNG.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_bytes(result)
    temporary.replace(destination)
    return width, height


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("ready_marker", type=Path)
    args = parser.parse_args()
    try:
        marker = json.loads(args.ready_marker.read_text())
        width, height = encode_opaque(args.source, args.destination, marker)
    except (OSError, ValueError, struct.error, zlib.error) as error:
        print(f"Apple screenshot rejected: {error}", file=sys.stderr)
        return 1
    print(f"Verified opaque RGB PNG: {args.destination} ({width}×{height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
