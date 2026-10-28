"""Render the original code-drawn Bridge mark; development-only dependency: Pillow."""

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def render():
    scale = 16
    image = Image.new("RGB", (256 * scale, 256 * scale), "#153b35")
    draw = ImageDraw.Draw(image)
    cream = "#fbf9f2"
    points = [(70, 166), (70, 108)]
    for step in range(81):
        t = step / 80
        points.append(((1 - t) ** 2 * 70 + 2 * (1 - t) * t * 128 + t ** 2 * 186,
                       (1 - t) ** 2 * 108 + 2 * (1 - t) * t * 34 + t ** 2 * 108))
    points.append((186, 166))
    draw.line([(round(x * scale), round(y * scale)) for x, y in points], fill=cream, width=10 * scale, joint="curve")
    draw.line([(70 * scale, 134 * scale), (186 * scale, 134 * scale)], fill=cream, width=10 * scale)
    for x, y in ((70, 166), (186, 166), (70, 134), (186, 134)):
        draw.ellipse(((x - 5) * scale, (y - 5) * scale, (x + 5) * scale, (y + 5) * scale), fill=cream)
    for x, color in ((70, "#edaa7d"), (186, cream)):
        draw.ellipse(((x - 10) * scale, 176 * scale, (x + 10) * scale, 196 * scale), fill=color)
    return image


def main():
    image = render()
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        target = ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"
        image.resize((size, size), Image.Resampling.LANCZOS).save(target)
    folder = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for icon in json.loads((folder / "Contents.json").read_text())["images"]:
        if "filename" not in icon:
            continue
        size = round(float(icon["size"].split("x")[0]) * float(icon["scale"].rstrip("x")))
        image.resize((size, size), Image.Resampling.LANCZOS).save(folder / icon["filename"])
    image.resize((256, 256), Image.Resampling.LANCZOS).save(
        ROOT / "windows/runner/resources/app_icon.ico", sizes=[(size, size) for size in (16, 32, 48, 64, 128, 256)])
    print("Generated independent Android, iOS, and desktop development icons.")


if __name__ == "__main__":
    main()
