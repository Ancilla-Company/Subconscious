import importlib.util
from pathlib import Path

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ENGINE_ICON = ROOT / "engine" / "src" / "subconscious_engine" / "app_icon.ico"
RUNNER_ICON = ROOT / "apps" / "unified_app" / "windows" / "runner" / "resources" / "app_icon.ico"

_spec = importlib.util.spec_from_file_location(
    "make_logos", ROOT / "packaging" / "msix" / "make_logos.py"
)
make_logos = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(make_logos)

SOURCE = make_logos.load_source(ENGINE_ICON)


@pytest.fixture(scope="module")
def assets(tmp_path_factory):
    out = tmp_path_factory.mktemp("assets")
    make_logos.build_assets(SOURCE, out)
    return out


def _open(path):
    with Image.open(path) as img:
        img.load()
        return img.copy()


def _expected_files():
    expected = dict(make_logos.SIZES)
    for variant in ("unplated", "lightunplated"):
        for size in make_logos.TARGET_SIZES:
            expected[f"Square44x44Logo.targetsize-{size}_altform-{variant}.png"] = size
    return expected


def test_expected_files_sizes_and_mode(assets):
    for name, size in _expected_files().items():
        img = _open(assets / name)
        assert img.mode == "RGBA", name
        assert img.size == (size, size), name


@pytest.mark.parametrize("name,size", sorted(_expected_files().items()))
def test_artwork_matches_source(assets, name, size):
    img = _open(assets / name)
    expected = SOURCE.resize((size, size), Image.LANCZOS)
    assert list(img.getdata()) == list(expected.getdata()), name
    # Source corner is transparent, so the output corner must be too.
    assert SOURCE.getpixel((0, 0))[3] == 0
    # LANCZOS ringing from the source's rounded edge leaves at most alpha 2.
    assert img.getpixel((0, 0))[3] == expected.getpixel((0, 0))[3] <= 2, name
    # Centre keeps the source's own pixel (not recoloured).
    c = size // 2
    assert img.getpixel((c, c)) == expected.getpixel((c, c))


def test_unplated_variants_identical(assets):
    for size in make_logos.TARGET_SIZES:
        a = _open(assets / f"Square44x44Logo.targetsize-{size}_altform-unplated.png")
        b = _open(assets / f"Square44x44Logo.targetsize-{size}_altform-lightunplated.png")
        assert a.tobytes() == b.tobytes()


def test_runner_icon_is_original_source_icon():
    assert RUNNER_ICON.read_bytes() == ENGINE_ICON.read_bytes()
