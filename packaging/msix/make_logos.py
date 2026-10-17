"""Generate the MSIX tile/store logos from the engine's app icon (needs Pillow).

Every output is the source icon's own pixels resampled with LANCZOS; alpha is
preserved and nothing is recoloured, cropped or redrawn. The OS tile plate is
removed by the manifest (BackgroundColor="transparent") and the unplated
target-size assets, not by altering the artwork.

* ``StoreLogo.png`` / ``Square44x44Logo.png`` / ``Square150x150Logo.png``
* ``...targetsize-N_altform-unplated.png`` and ``..._altform-lightunplated.png``
  (identical artwork for both variants)

Usage: make_logos.py <icon.ico> <assets_dir>
"""

import argparse
from pathlib import Path

from PIL import Image

SIZES = {
    "StoreLogo.png": 50,
    "Square44x44Logo.png": 44,
    "Square150x150Logo.png": 150,
}
TARGET_SIZES = (16, 20, 24, 30, 32, 36, 40, 44, 48, 60, 64, 72, 80, 96, 256)


def load_source(path: str | Path) -> Image.Image:
    with Image.open(path) as icon:
        # .ico files hold several sizes; use the largest.
        sizes = icon.info.get("sizes") or {icon.size}
        icon.size = max(sizes)
        return icon.convert("RGBA")


def build_assets(source: Image.Image, out_dir: str | Path) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, size in SIZES.items():
        source.resize((size, size), Image.LANCZOS).save(out / name)
    for size in TARGET_SIZES:
        logo = source.resize((size, size), Image.LANCZOS)
        for variant in ("unplated", "lightunplated"):
            logo.save(out / f"Square44x44Logo.targetsize-{size}_altform-{variant}.png")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("icon")
    parser.add_argument("assets_dir")
    args = parser.parse_args()
    build_assets(load_source(args.icon), args.assets_dir)


if __name__ == "__main__":
    main()
