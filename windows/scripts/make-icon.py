#!/usr/bin/env python3
"""Build LinFlow.App/lin-flow.ico from the Mac app's icon.

Run from windows/:  python scripts/make-icon.py

The source is ../assets/AppIcon-1024.png, the same artwork the Mac ships, so the two apps carry
one mark and it only has to be drawn once.

It cannot be used as-is. macOS icons are drawn with a wide transparent margin - this one is 100 px
on every side of a 1024 px canvas, so the tile fills 80% of it - and the Dock takes that margin as
part of the grid. Windows does not: the taskbar draws an icon to the edge of its box, so the same
file next to Chrome and Teams reads as visibly smaller than everything around it. So the artwork
is cropped to its own pixels and fills the canvas edge to edge.

Both numbers here were measured off a screenshot of John's taskbar rather than guessed, by
sampling the drawn extent of each button: Windows App and RealVNC fill 48x48, Outlook 46x44. A
first attempt that left a 2% hairline for the rounded corners drew 40x40 and still read as small,
so the hairline went.

Entries are written as BMP, not PNG, below 256. Pillow writes every entry as PNG, and PNG inside
an .ico is only dependably read at 256 - the shell skips what it cannot decode and falls back to
another size without scaling it up, which is the other half of why the taskbar drew 40 px into a
48 px box. 256 stays PNG because that is the size the format expects it for.

Nine sizes because Windows asks for different ones in different places: 16 in a title bar, 32 in
Alt-Tab, 48 on this 200% taskbar, 256 in Explorer's large view. Leaving one out makes Windows
resample a neighbor, which looks soft.
"""

import io
import struct
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / "assets" / "AppIcon-1024.png"
TARGET = HERE.parent / "LinFlow.App" / "lin-flow.ico"

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]

# Above this, an entry is stored as PNG; at or below it, as a BMP the shell will certainly read.
PNG_FROM = 256


def main() -> None:
    art = Image.open(SOURCE).convert("RGBA")

    # Crop to the pixels that are actually drawn. Alpha over 8 rather than over 0 so a stray
    # almost-transparent pixel from the source's shadow does not defeat the crop.
    box = art.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    if box is None:
        raise SystemExit(f"{SOURCE} looks empty")
    art = art.crop(box)

    # Square it off, so a source that is not exactly square cannot end up stretched.
    side = max(art.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(art, ((side - art.width) // 2, (side - art.height) // 2))

    TARGET.write_bytes(build_ico(square))
    print(f"{TARGET.name}: {len(SIZES)} sizes, artwork fills the canvas "
          f"(80% of it in {SOURCE.name}); BMP below {PNG_FROM}, PNG at {PNG_FROM}")


def build_ico(art: Image.Image) -> bytes:
    """An ICO file: a header, one directory entry per size, then the images."""
    images = [(n, encode(art.resize((n, n), Image.LANCZOS), n)) for n in SIZES]

    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    directory, body = b"", b""
    for n, blob in images:
        # 0 means 256 in a directory entry: the field is one byte.
        directory += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
        body += blob
    return header + directory + body


def encode(image: Image.Image, n: int) -> bytes:
    if n >= PNG_FROM:
        out = io.BytesIO()
        image.save(out, format="PNG")
        return out.getvalue()

    # A BMP entry: BITMAPINFOHEADER with twice the height (the color rows, then the AND mask),
    # then bottom-up BGRA rows, then the mask. The mask is all zeros because 32-bit entries are
    # masked by their own alpha, but it has to be there and it has to be the right size: its rows
    # are 1 bit per pixel padded out to 4 bytes.
    head = struct.pack("<IiiHHIIiiII", 40, n, n * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = bytearray()
    pixels = image.load()
    for y in range(n - 1, -1, -1):
        for x in range(n):
            r, g, b, a = pixels[x, y]
            rows += bytes((b, g, r, a))
    mask_stride = ((n + 31) // 32) * 4
    return head + bytes(rows) + bytes(mask_stride * n)


if __name__ == "__main__":
    main()
