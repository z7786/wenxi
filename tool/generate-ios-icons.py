"""Generate opaque, square iOS icons from the existing app artwork (Pillow).

Run this script separately from generate-app-icons.py: the Android and desktop
artwork has baked rounded corners, while iOS must apply its own corner mask.
The existing blue background is extended to the edges without changing the logo.
"""
from __future__ import annotations

import json
from bisect import bisect_left
from decimal import Decimal
from pathlib import Path

from PIL import Image
from PIL.PngImagePlugin import PngInfo

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/icons/app.png"
ICON_SET = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"


def is_background(pixel: tuple[int, int, int, int]) -> bool:
    red, _, blue, alpha = pixel
    # Skip the transparent padding and the light antialiasing of the old mask.
    return alpha >= 250 and blue > 200 and blue - red > 100


def square_artwork() -> Image.Image:
    with Image.open(SOURCE) as image:
        artwork = image.convert("RGBA")
    pixels = artwork.load()
    background_mask = Image.new("L", artwork.size)
    background_mask.putdata([255 if is_background(pixels[x, y]) else 0
                             for y in range(artwork.height)
                             for x in range(artwork.width)])
    bounds = background_mask.getbbox()
    if bounds is None:
        raise ValueError("Expected the existing blue app artwork")

    # Trim the padding and two edge pixels that can contain the old outline.
    left, top, right, bottom = bounds
    side = min(right - left, bottom - top) - 4
    if side < 128:
        raise ValueError("App artwork is too small")
    left += (right - left - side) // 2
    top += (bottom - top - side) // 2
    artwork = artwork.crop((left, top, left + side, top + side))
    pixels = artwork.load()
    result = Image.new("RGB", artwork.size)
    output = result.load()
    for y in range(side):
        background = [x for x in range(side) if is_background(pixels[x, y])]
        if len(background) < 8:
            raise ValueError(f"Missing blue background on row {y}")
        # Extend the row's original background colors into the rounded corners.
        start, end = background[4], background[-5]
        for x in range(side):
            sample_x = min(end, max(start, x))
            pixel = pixels[sample_x, y]
            if pixel[3] < 250:
                # The palette can retain a few partly transparent outline pixels
                # even inside the cropped row; use the closest clean blue pixel.
                index = bisect_left(background, sample_x)
                sample_x = min(background[index - 1:index + 1],
                               key=lambda candidate: abs(candidate - sample_x))
                pixel = pixels[sample_x, y]
            output[x, y] = pixel[:3]
    return result


def main() -> None:
    contents = json.loads((ICON_SET / "Contents.json").read_text(encoding="utf-8"))
    sizes: dict[str, int] = {}
    for entry in contents["images"]:
        width, height = map(Decimal, entry["size"].split("x"))
        scale = Decimal(entry["scale"].removesuffix("x"))
        pixels = width * scale
        if width != height or pixels != int(pixels):
            raise ValueError(f"Invalid icon dimensions: {entry}")
        filename = entry["filename"]
        if Path(filename).name != filename:
            raise ValueError("Icon filename must be inside the asset catalog")
        size = int(pixels)
        if filename in sizes and sizes[filename] != size:
            raise ValueError(f"Conflicting sizes for {filename}")
        sizes[filename] = size

    artwork = square_artwork()
    metadata = PngInfo()
    metadata.add(b"sRGB", b"\x00")
    for filename, size in sizes.items():
        icon = artwork.resize((size, size), Image.Resampling.LANCZOS)
        icon.save(ICON_SET / filename, pnginfo=metadata, optimize=True)
    print(f"Generated {len(sizes)} opaque, square iOS icons")


if __name__ == "__main__":
    main()
