"""Generate the MSIX tile/store logos from the engine's app icon (needs Pillow)."""

import sys
from pathlib import Path

from PIL import Image

SIZES = {
    "StoreLogo.png": 50,
    "Square44x44Logo.png": 44,
    "Square150x150Logo.png": 150,
}


def main(icon_path: str, output_dir: str) -> None:
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    with Image.open(icon_path) as icon:
        # .ico files hold several sizes; use the largest.
        sizes = icon.info.get("sizes") or {icon.size}
        icon.size = max(sizes)
        source = icon.convert("RGBA")
    for name, size in SIZES.items():
        source.resize((size, size), Image.LANCZOS).save(out / name)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
