"""
Unit tests for subconscious.tools.images

Tests image conversion and resize tools using Pillow to create test images.
"""

import pathlib
import pytest
import pytest_asyncio
from PIL import Image

from subconscious.desktop_tools.images import (
  convert_image,
  optimize_image,
  resize_image,
  batch_convert_image,
  batch_optimize_images,
  batch_resize_images,
)


# ---------------------------------------------------------------------------
# Fixture: temporary directory
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture
async def tmp_dir(tmp_path):
  return tmp_path


# ---------------------------------------------------------------------------
# Helper: create test image
# ---------------------------------------------------------------------------

def create_test_png(path: pathlib.Path, size=(100, 100), color=(255, 0, 0)):
  """Create a simple PNG test image."""
  img = Image.new('RGB', size, color)
  img.save(path, 'PNG')


def create_test_jpg(path: pathlib.Path, size=(100, 100), color=(0, 255, 0)):
  """Create a simple JPG test image."""
  img = Image.new('RGB', size, color)
  img.save(path, 'JPEG')


def create_test_bmp(path: pathlib.Path, size=(100, 100), color=(0, 0, 255)):
  """Create a simple BMP test image."""
  img = Image.new('RGB', size, color)
  img.save(path, 'BMP')


def create_test_tiff(path: pathlib.Path, size=(100, 100), color=(255, 255, 0)):
  """Create a simple TIFF test image."""
  img = Image.new('RGB', size, color)
  img.save(path, 'TIFF')


def create_test_gif(path: pathlib.Path, size=(100, 100), color=(255, 0, 255)):
  """Create a simple GIF test image."""
  img = Image.new('P', size, color)
  img.save(path, 'GIF')


def create_test_webp(path: pathlib.Path, size=(100, 100), color=(0, 255, 255)):
  """Create a simple WebP test image."""
  img = Image.new('RGB', size, color)
  img.save(path, 'WEBP')


def create_test_ico(path: pathlib.Path, size=(64, 64), color=(128, 128, 128)):
  """Create a simple ICO test image."""
  img = Image.new('RGBA', size, color + (255,))
  img.save(path, 'ICO')


# ---------------------------------------------------------------------------
# optimize_image
# ---------------------------------------------------------------------------

async def test_optimize_image_png(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "optimized.png"
  create_test_png(input_path, size=(200, 200))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=100)
  assert "Successfully optimized" in result
  assert output_path.exists()

  # 200x200 scaled down so longest side == 100 → 100x100
  with Image.open(output_path) as img:
    assert img.size == (100, 100)


async def test_optimize_image_overwrite(ctx, tmp_dir):
  input_path = tmp_dir / "test.jpg"
  create_test_jpg(input_path)

  result = await optimize_image(ctx, str(input_path))
  assert "Successfully optimized" in result
  assert input_path.exists()  # Overwrites input


async def test_optimize_image_jpg(ctx, tmp_dir):
  input_path = tmp_dir / "test.jpg"
  output_path = tmp_dir / "optimized.jpg"
  create_test_jpg(input_path, size=(200, 200))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=100)
  assert "Successfully optimized" in result
  assert output_path.exists()

  with Image.open(output_path) as img:
    assert img.size == (100, 100)


async def test_optimize_image_bmp(ctx, tmp_dir):
  input_path = tmp_dir / "test.bmp"
  output_path = tmp_dir / "optimized.bmp"
  create_test_bmp(input_path, size=(200, 200))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=100)
  assert "Successfully optimized" in result
  assert output_path.exists()

  with Image.open(output_path) as img:
    assert img.size == (100, 100)


async def test_optimize_image_tiff(ctx, tmp_dir):
  input_path = tmp_dir / "test.tiff"
  output_path = tmp_dir / "optimized.tiff"
  create_test_tiff(input_path, size=(200, 200))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=100)
  assert "Successfully optimized" in result
  assert output_path.exists()

  with Image.open(output_path) as img:
    assert img.size == (100, 100)


async def test_optimize_image_gif(ctx, tmp_dir):
  input_path = tmp_dir / "test.gif"
  output_path = tmp_dir / "optimized.gif"
  create_test_gif(input_path, size=(200, 200))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=100)
  assert "Successfully optimized" in result
  assert output_path.exists()

  with Image.open(output_path) as img:
    assert img.size == (100, 100)


async def test_optimize_image_webp(ctx, tmp_dir):
  input_path = tmp_dir / "test.webp"
  output_path = tmp_dir / "optimized.webp"
  create_test_webp(input_path, size=(200, 200))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=100)
  assert "Successfully optimized" in result
  assert output_path.exists()

  with Image.open(output_path) as img:
    assert img.size == (100, 100)


async def test_optimize_image_ico(ctx, tmp_dir):
  input_path = tmp_dir / "test.ico"
  output_path = tmp_dir / "optimized.ico"
  create_test_ico(input_path, size=(64, 64))

  result = await optimize_image(ctx, str(input_path), str(output_path), max_size=32)
  assert "Successfully optimized" in result
  assert output_path.exists()

  # ICO is capped at min(new_size, 256)
  with Image.open(output_path) as img:
    assert img.size == (32, 32)


# ---------------------------------------------------------------------------
# convert_image (general converter)
# ---------------------------------------------------------------------------

async def test_convert_image_png_to_jpg(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "output.jpg"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'JPG', str(output_path))
  assert "Successfully converted" in result and "JPG" in result
  assert output_path.exists()
  assert output_path.suffix == ".jpg"


async def test_convert_image_jpg_to_png(ctx, tmp_dir):
  input_path = tmp_dir / "test.jpg"
  output_path = tmp_dir / "output.png"
  create_test_jpg(input_path)

  result = await convert_image(ctx, str(input_path), 'PNG', str(output_path))
  assert "Successfully converted" in result and "PNG" in result
  assert output_path.exists()
  assert output_path.suffix == ".png"


async def test_convert_image_png_to_webp(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "output.webp"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'WEBP', str(output_path))
  assert "Successfully converted" in result and "WEBP" in result
  assert output_path.exists()
  assert output_path.suffix == ".webp"


async def test_convert_image_jpg_to_pdf(ctx, tmp_dir):
  input_path = tmp_dir / "test.jpg"
  output_path = tmp_dir / "output.pdf"
  create_test_jpg(input_path)

  result = await convert_image(ctx, str(input_path), 'PDF', str(output_path))
  assert "Successfully converted" in result and "PDF" in result
  assert output_path.exists()
  assert output_path.suffix == ".pdf"


async def test_convert_image_auto_output(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'JPG')
  expected_output = input_path.with_suffix('.jpg')
  assert "Successfully converted" in result and "JPG" in result
  assert expected_output.exists()


async def test_convert_image_unsupported_format(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'UNSUPPORTED')
  assert "Unsupported output format" in result


async def test_convert_image_invalid_input(ctx, tmp_dir):
  result = await convert_image(ctx, str(tmp_dir / "missing.png"), 'JPG')
  assert "not exist" in result.lower()


# ---------------------------------------------------------------------------
# convert_image (JPG conversions)
# ---------------------------------------------------------------------------

async def test_convert_image_to_jpg_png(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "output.jpg"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'JPG', str(output_path))
  assert "Successfully converted" in result and "JPG" in result
  assert output_path.exists()
  assert output_path.suffix == ".jpg"


async def test_convert_image_to_jpg_auto_output(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'JPG')
  expected_output = input_path.with_suffix('.jpg')
  assert "Successfully converted" in result and "JPG" in result
  assert expected_output.exists()


# ---------------------------------------------------------------------------
# convert_image (PDF conversions)
# ---------------------------------------------------------------------------

async def test_convert_image_to_pdf_png(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "output.pdf"
  create_test_png(input_path)

  result = await convert_image(ctx, str(input_path), 'PDF', str(output_path))
  assert "Successfully converted" in result and "PDF" in result
  assert output_path.exists()
  assert output_path.suffix == ".pdf"


async def test_convert_image_to_pdf_jpg(ctx, tmp_dir):
  input_path = tmp_dir / "test.jpg"
  create_test_jpg(input_path)

  result = await convert_image(ctx, str(input_path), 'PDF')
  expected_output = input_path.with_suffix('.pdf')
  assert "Successfully converted" in result and "PDF" in result
  assert expected_output.exists()


# ---------------------------------------------------------------------------
# batch_optimize_images
# ---------------------------------------------------------------------------

async def test_batch_optimize_images(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  create_test_png(src_dir / "test1.png")
  create_test_jpg(src_dir / "test2.jpg")
  create_test_bmp(src_dir / "test3.bmp")
  create_test_webp(src_dir / "test4.webp")
  create_test_ico(src_dir / "test5.ico")

  result = await batch_optimize_images(ctx, str(src_dir), str(dest_dir))
  assert "Processed 5 images" in result
  assert (dest_dir / "test1.png").exists()
  assert (dest_dir / "test2.jpg").exists()
  assert (dest_dir / "test3.bmp").exists()
  assert (dest_dir / "test4.webp").exists()
  assert (dest_dir / "test5.ico").exists()


# ---------------------------------------------------------------------------
# batch_convert_image
# ---------------------------------------------------------------------------

async def test_batch_convert_image_to_png(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  create_test_png(src_dir / "test1.png")
  create_test_jpg(src_dir / "test2.jpg")

  result = await batch_convert_image(ctx, str(src_dir), str(dest_dir), 'PNG')
  assert "Converted 2 images to PNG" in result
  assert (dest_dir / "test1.png").exists()
  assert (dest_dir / "test2.png").exists()


async def test_batch_convert_image_to_webp(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  create_test_png(src_dir / "test1.png")
  create_test_jpg(src_dir / "test2.jpg")

  result = await batch_convert_image(ctx, str(src_dir), str(dest_dir), 'WEBP', quality=90)
  assert "Converted 2 images to WEBP" in result
  assert (dest_dir / "test1.webp").exists()
  assert (dest_dir / "test2.webp").exists()


async def test_batch_convert_image_to_jpg(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  create_test_png(src_dir / "test1.png")
  create_test_jpg(src_dir / "test2.jpg")

  result = await batch_convert_image(ctx, str(src_dir), str(dest_dir), 'JPG')
  assert "Converted 2 images to JPG" in result
  assert (dest_dir / "test1.jpg").exists()
  assert (dest_dir / "test2.jpg").exists()


async def test_batch_convert_image_to_pdf(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  create_test_png(src_dir / "test1.png")
  create_test_jpg(src_dir / "test2.jpg")

  result = await batch_convert_image(ctx, str(src_dir), str(dest_dir), 'PDF')
  assert "Converted 2 images to PDF" in result
  assert (dest_dir / "test1.pdf").exists()
  assert (dest_dir / "test2.pdf").exists()


async def test_batch_convert_image_empty_directory(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  result = await batch_convert_image(ctx, str(src_dir), str(dest_dir), 'JPG')
  assert "Converted 0 images to JPG" in result


# ---------------------------------------------------------------------------
# optimize_image — additional behaviour tests
# ---------------------------------------------------------------------------

async def test_optimize_image_no_upscale(ctx, tmp_dir):
  """Images smaller than max_size must not be upscaled."""
  input_path = tmp_dir / "small.png"
  output_path = tmp_dir / "out.png"
  create_test_png(input_path, size=(50, 50))

  await optimize_image(ctx, str(input_path), str(output_path), max_size=200)

  with Image.open(output_path) as img:
    assert img.size == (50, 50)  # unchanged


async def test_optimize_image_aspect_ratio_preserved(ctx, tmp_dir):
  """Non-square images must keep their aspect ratio after optimization."""
  input_path = tmp_dir / "wide.png"
  output_path = tmp_dir / "out.png"
  # 400×200 with max_size=200 → longest side (400) → 200×100
  img = Image.new('RGB', (400, 200), (0, 128, 255))
  img.save(input_path, 'PNG')

  await optimize_image(ctx, str(input_path), str(output_path), max_size=200)

  with Image.open(output_path) as img_out:
    assert img_out.size == (200, 100)


# ---------------------------------------------------------------------------
# resize_image
# ---------------------------------------------------------------------------

async def test_resize_image_explicit_dimensions(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "resized.png"
  create_test_png(input_path, size=(400, 400))

  result = await resize_image(ctx, str(input_path), 200, 200, str(output_path))
  assert "Successfully resized" in result
  assert "200×200" in result
  with Image.open(output_path) as img:
    assert img.size == (200, 200)


async def test_resize_image_maintain_aspect_ratio(ctx, tmp_dir):
  """400×200 image resized into a 200×200 box with AR → 200×100."""
  input_path = tmp_dir / "wide.png"
  output_path = tmp_dir / "resized.png"
  img = Image.new('RGB', (400, 200), (0, 0, 0))
  img.save(input_path, 'PNG')

  result = await resize_image(ctx, str(input_path), 200, 200, str(output_path),
                              maintain_aspect_ratio=True)
  assert "Successfully resized" in result
  with Image.open(output_path) as img_out:
    assert img_out.size == (200, 100)


async def test_resize_image_no_aspect_ratio(ctx, tmp_dir):
  """Without AR preservation the image is stretched to exact dimensions."""
  input_path = tmp_dir / "wide.png"
  output_path = tmp_dir / "resized.png"
  img = Image.new('RGB', (400, 200), (0, 0, 0))
  img.save(input_path, 'PNG')

  result = await resize_image(ctx, str(input_path), 150, 100, str(output_path),
                              maintain_aspect_ratio=False)
  assert "Successfully resized" in result
  with Image.open(output_path) as img_out:
    assert img_out.size == (150, 100)


async def test_resize_image_derive_width_from_height(ctx, tmp_dir):
  """width=0 → derived from height to preserve aspect ratio."""
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "resized.png"
  create_test_png(input_path, size=(400, 200))

  result = await resize_image(ctx, str(input_path), 0, 100, str(output_path))
  assert "Successfully resized" in result
  with Image.open(output_path) as img:
    assert img.size == (200, 100)  # width proportionally halved


async def test_resize_image_derive_height_from_width(ctx, tmp_dir):
  """height=0 → derived from width."""
  input_path = tmp_dir / "test.png"
  output_path = tmp_dir / "resized.png"
  create_test_png(input_path, size=(400, 200))

  result = await resize_image(ctx, str(input_path), 200, 0, str(output_path))
  assert "Successfully resized" in result
  with Image.open(output_path) as img:
    assert img.size == (200, 100)


async def test_resize_image_rejects_upscale(ctx, tmp_dir):
  """Requesting dimensions larger than the original must be rejected."""
  input_path = tmp_dir / "small.png"
  create_test_png(input_path, size=(100, 100))

  result = await resize_image(ctx, str(input_path), 500, 500)
  assert "Upscaling is not supported" in result


async def test_resize_image_overwrites_input(ctx, tmp_dir):
  """output_path=None should overwrite the original file."""
  input_path = tmp_dir / "test.png"
  create_test_png(input_path, size=(200, 200))

  result = await resize_image(ctx, str(input_path), 100, 100)
  assert "Successfully resized" in result
  with Image.open(input_path) as img:
    assert img.size == (100, 100)


async def test_resize_image_invalid_path(ctx, tmp_dir):
  result = await resize_image(ctx, str(tmp_dir / "missing.png"), 100, 100)
  assert "not exist" in result.lower()


async def test_resize_image_both_zero(ctx, tmp_dir):
  input_path = tmp_dir / "test.png"
  create_test_png(input_path, size=(200, 200))
  result = await resize_image(ctx, str(input_path), 0, 0)
  assert "at least one" in result.lower()


# ---------------------------------------------------------------------------
# batch_resize_images
# ---------------------------------------------------------------------------

async def test_batch_resize_images(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()
  create_test_png(src_dir / "a.png", size=(300, 300))
  create_test_jpg(src_dir / "b.jpg", size=(300, 300))

  result = await batch_resize_images(ctx, str(src_dir), str(dest_dir),
                                     width=150, height=150)
  assert "Resized 2 images" in result
  for name in ("a.png", "b.jpg"):
    with Image.open(dest_dir / name) as img:
      assert img.size == (150, 150)


async def test_batch_resize_images_aspect_ratio(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()
  # 400×200 → fit into 200×200 box with AR → 200×100
  img = Image.new('RGB', (400, 200), (0, 0, 0))
  img.save(src_dir / "wide.png", 'PNG')

  result = await batch_resize_images(ctx, str(src_dir), str(dest_dir),
                                     width=200, height=200,
                                     maintain_aspect_ratio=True)
  assert "Resized 1 images" in result
  with Image.open(dest_dir / "wide.png") as img_out:
    assert img_out.size == (200, 100)


async def test_batch_resize_images_skips_upscale(ctx, tmp_dir):
  """Files that would require upscaling should appear in the errors list."""
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()
  create_test_png(src_dir / "tiny.png", size=(50, 50))

  result = await batch_resize_images(ctx, str(src_dir), str(dest_dir),
                                     width=200, height=200)
  assert "Resized 0 images" in result
  assert "Errors" in result


async def test_batch_resize_images_empty_directory(ctx, tmp_dir):
  src_dir = tmp_dir / "src"
  dest_dir = tmp_dir / "dest"
  src_dir.mkdir()

  result = await batch_resize_images(ctx, str(src_dir), str(dest_dir), width=100, height=100)
  assert "Resized 0 images" in result