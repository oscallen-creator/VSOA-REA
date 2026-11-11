# Builds every app icon from assets/um-logo.jpg (the UM logo on a flat navy background):
# a navy circle around the logo, written as icon.png, icon.icns, icon.ico and icons/NxN.png.
# Run from the app folder: python3 scripts/make-icons.py   (needs Pillow; icon.icns needs macOS)
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ASSETS = Path("assets")
SIZE, BODY = 1024, 824  # canvas and circle diameter: the 824 px body of Apple's 1024 icon grid
SS = 4  # supersampling for a smooth circle edge

src = Image.open(ASSETS / "um-logo.jpg").convert("RGB")
navy = src.getpixel((0, 0))

# The logo is every pixel clearly off the navy; snap the rest to flat navy to drop JPEG noise.
off = ImageChops.difference(src, Image.new("RGB", src.size, navy)).convert("L")
src = Image.composite(src, Image.new("RGB", src.size, navy), off.point(lambda v: 255 if v > 12 else 0))
logo = off.point(lambda v: 255 if v > 40 else 0)
left, top, right, bottom = logo.getbbox()
cx, cy = (left + right) / 2, (top + bottom) / 2

# Circle radius: the farthest logo pixel from the centre, plus breathing room.
pts = logo.resize((logo.width // 4, logo.height // 4)).getdata()
w4 = logo.width // 4
far = max(((i % w4) * 4 - cx) ** 2 + ((i // w4) * 4 - cy) ** 2 for i, v in enumerate(pts) if v) ** 0.5
radius = far * 1.12

crop = src.crop((round(cx - radius), round(cy - radius), round(cx + radius), round(cy + radius)))
body = crop.resize((BODY, BODY), Image.LANCZOS)
mask = Image.new("L", (BODY * SS, BODY * SS), 0)
ImageDraw.Draw(mask).ellipse((0, 0, BODY * SS - 1, BODY * SS - 1), fill=255)
icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
pad = (SIZE - BODY) // 2
icon.paste(body, (pad, pad), mask.resize((BODY, BODY), Image.LANCZOS))

icon.save(ASSETS / "icon.png")
icon.save(ASSETS / "icon.ico", sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
icons = ASSETS / "icons"
icons.mkdir(exist_ok=True)
for n in (16, 32, 48, 64, 128, 256, 512, 1024):
    icon.resize((n, n), Image.LANCZOS).save(icons / f"{n}x{n}.png")

if shutil.which("iconutil"):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "icon.iconset"
        iconset.mkdir()
        for n in (16, 32, 128, 256, 512):
            icon.resize((n, n), Image.LANCZOS).save(iconset / f"icon_{n}x{n}.png")
            icon.resize((n * 2, n * 2), Image.LANCZOS).save(iconset / f"icon_{n}x{n}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ASSETS / "icon.icns")], check=True)
else:
    print("iconutil not found (not macOS): icon.icns left as it was")
print(f"logo centre ({cx:.0f}, {cy:.0f}), circle radius {radius:.0f} px of source; icons written to {ASSETS}/")
