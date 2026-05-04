
"""
Image processing tools — resize, optimize, and convert images.
Supports various image formats via Pillow (PIL).

Resize policy: downscale only — target dimensions must be smaller than the
original. Upscaling is rejected to prevent unintentional quality loss.
"""

import os
import pathlib
import logging
from typing import Optional
from PIL import Image
from pydantic_ai import RunContext

from . import EngineContext


logger = logging.getLogger("subconscious")


async def optimize_image(
  ctx: RunContext[EngineContext],
  input_path: str,
  output_path: Optional[str] = None,
  quality: int = 85,
  max_size: int = 1024,
) -> str:
  """
  Optimize a single image file by capping its longest side at *max_size* pixels
  (aspect-ratio preserved) and saving with compression.

  The image is only ever downscaled — if the original is already smaller than
  *max_size* on both sides it is saved as-is without upscaling.

  Supports input/output formats: JPG, JPEG, PNG, BMP, TIFF, GIF, WebP, ICO.

  Args:
      input_path: Path to the input image file.
      output_path: Path for the optimized image. If None, overwrites input file.
      quality: Quality for JPEG/WebP (1-100, default 85).
      max_size: Maximum pixel length of the longest side (default 1024).

  Returns:
      Success message or error description.
  """
  try:
    input_p = pathlib.Path(input_path).expanduser().resolve()
    if not input_p.exists() or not input_p.is_file():
      return f"Error: Input file '{input_path}' does not exist or is not a file."

    if output_path is None:
      output_path = str(input_p)
    output_p = pathlib.Path(output_path).expanduser().resolve()
    output_p.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(input_p) as img:
      original_format = img.format or 'JPEG'
      orig_w, orig_h = img.size

      # Cap at max_size on the longest side, preserving aspect ratio.
      # Never upscale.
      scale = min(max_size / orig_w, max_size / orig_h, 1.0)
      new_w = int(orig_w * scale)
      new_h = int(orig_h * scale)
      optimized = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

      if original_format.upper() in ('JPEG', 'JPG'):
        optimized.save(output_p, format='JPEG', quality=quality, optimize=True)
      elif original_format.upper() == 'PNG':
        optimized.save(output_p, format='PNG', optimize=True)
      elif original_format.upper() == 'ICO':
        if optimized.mode not in ('RGB', 'RGBA'):
          optimized = optimized.convert('RGBA')
        # ICO spec: max 256×256
        ico_size = min(new_w, new_h, 256)
        ico_img = optimized.resize((ico_size, ico_size), Image.Resampling.LANCZOS)
        ico_img.save(output_p, format='ICO')
      else:
        optimized.save(output_p, format=original_format)

    return f"Successfully optimized '{input_path}' and saved to '{output_path}'."

  except Exception as e:
    logger.error(f"Error optimizing image: {e}")
    return f"Error optimizing image: {e}"


async def convert_image(
  ctx: RunContext[EngineContext],
  input_path: str,
  output_format: str,
  output_path: Optional[str] = None,
  quality: int = 85,
) -> str:
  """
  Convert a single image file to the specified output format.

  Supported input formats: JPG, JPEG, PNG, BMP, TIFF, GIF, WebP, ICO
  Supported output formats: JPG, PNG, BMP, TIFF, GIF, WebP, ICO, PDF

  Args:
      input_path: Path to the input image file.
      output_format: Desired output format (case-insensitive: 'JPG', 'PNG', 'WEBP', 'PDF', etc.).
      output_path: Path for the output file. If None, uses input path with new extension.
      quality: Quality for lossy formats like JPG/WebP (1-100, default 85). Ignored for lossless formats.

  Returns:
      Success message or error description.
  """
  try:
    input_p = pathlib.Path(input_path).expanduser().resolve()
    if not input_p.exists() or not input_p.is_file():
      return f"Error: Input file '{input_path}' does not exist or is not a file."

    # Normalize output format
    output_format = output_format.upper()
    supported_outputs = {'JPG', 'JPEG', 'PNG', 'BMP', 'TIFF', 'GIF', 'WEBP', 'ICO', 'PDF'}
    if output_format not in supported_outputs:
      return f"Error: Unsupported output format '{output_format}'. Supported: {', '.join(sorted(supported_outputs))}"

    # Determine output path
    if output_path is None:
      ext = '.jpg' if output_format in ('JPG', 'JPEG') else f'.{output_format.lower()}'
      output_path = str(input_p.with_suffix(ext))
    output_p = pathlib.Path(output_path).expanduser().resolve()
    output_p.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(input_p) as img:
      # Handle format-specific requirements
      if output_format in ('JPG', 'JPEG'):
        # Convert to RGB for JPG
        if img.mode not in ('RGB', 'L'):
          img = img.convert('RGB')
        img.save(output_p, 'JPEG', quality=quality, optimize=True)
      elif output_format == 'PNG':
        img.save(output_p, 'PNG', optimize=True)
      elif output_format == 'WEBP':
        # Convert to RGB if necessary
        if img.mode in ('RGBA', 'P'):
          img = img.convert('RGB')
        img.save(output_p, 'WEBP', quality=quality, optimize=True)
      elif output_format == 'ICO':
        # Convert to RGBA if necessary for ICO
        if img.mode not in ('RGB', 'RGBA'):
          img = img.convert('RGBA')
        # Resize to standard ICO size if too large
        if img.size[0] > 256 or img.size[1] > 256:
          img = img.resize((256, 256), Image.Resampling.LANCZOS)
        img.save(output_p, 'ICO')
      elif output_format == 'PDF':
        # Convert to RGB for PDF
        if img.mode in ('RGBA', 'P'):
          img = img.convert('RGB')
        img.save(output_p, 'PDF')
      else:
        # For BMP, TIFF, GIF - save as-is
        img.save(output_p, output_format)

    return f"Successfully converted '{input_path}' to {output_format} at '{output_path}'."

  except Exception as e:
    logger.error(f"Error converting image: {e}")
    return f"Error converting image: {e}"


async def batch_optimize_images(
  ctx: RunContext[EngineContext],
  src_directory: str = ".",
  dest_directory: str = "optimized",
  quality: int = 85,
  max_size: int = 1024,
) -> str:
  """
  Optimize all images in a source directory and save to destination directory.

  Args:
      src_directory: Source directory path.
      dest_directory: Destination directory path.
      quality: Quality for lossy formats (default 85).
      max_size: Maximum pixel length of the longest side (default 1024).

  Returns:
      Summary of operations.
  """
  try:
    src_p = pathlib.Path(src_directory).expanduser().resolve()
    dest_p = pathlib.Path(dest_directory).expanduser().resolve()
    dest_p.mkdir(parents=True, exist_ok=True)

    supported_formats = (".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".gif", ".webp", ".ico")
    processed = 0
    errors = []

    for filename in os.listdir(src_p):
      if filename.lower().endswith(supported_formats):
        input_path = src_p / filename
        output_path = dest_p / filename
        result = await optimize_image(ctx, str(input_path), str(output_path), quality, max_size)
        if "Successfully" in result:
          processed += 1
        else:
          errors.append(f"{filename}: {result}")

    result = f"Processed {processed} images."
    if errors:
      result += f" Errors: {', '.join(errors)}"
    return result

  except Exception as e:
    logger.error(f"Error in batch optimize: {e}")
    return f"Error in batch optimize: {e}"


async def batch_convert_image(
  ctx: RunContext[EngineContext],
  src_directory: str = ".",
  dest_directory: str = "converted",
  output_format: str = "JPG",
  quality: int = 85,
) -> str:
  """
  Convert all images in a source directory to the specified format and save to destination directory.

  Supported output formats: JPG, PNG, BMP, TIFF, GIF, WebP, ICO, PDF

  Args:
      src_directory: Source directory path.
      dest_directory: Destination directory path.
      output_format: Desired output format (case-insensitive).
      quality: Quality for lossy formats (default 85).

  Returns:
      Summary of operations.
  """
  try:
    src_p = pathlib.Path(src_directory).expanduser().resolve()
    dest_p = pathlib.Path(dest_directory).expanduser().resolve()
    dest_p.mkdir(parents=True, exist_ok=True)

    supported_formats = (".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".gif", ".webp", ".ico")
    processed = 0
    errors = []

    # Determine file extension for output format
    output_format = output_format.upper()
    if output_format in ('JPG', 'JPEG'):
      ext = '.jpg'
    elif output_format == 'PDF':
      ext = '.pdf'
    else:
      ext = f'.{output_format.lower()}'

    for filename in os.listdir(src_p):
      if filename.lower().endswith(supported_formats):
        input_path = src_p / filename
        new_filename = pathlib.Path(filename).with_suffix(ext)
        output_path = dest_p / new_filename
        try:
          result = await convert_image(ctx, str(input_path), output_format, str(output_path), quality)
          if "Successfully" in result:
            processed += 1
          else:
            errors.append(f"{filename}: {result}")
        except Exception as e:
          errors.append(f"{filename}: {e}")

    result = f"Converted {processed} images to {output_format}."
    if errors:
      result += f" Errors: {', '.join(errors)}"
    return result

  except Exception as e:
    logger.error(f"Error in batch convert to {output_format}: {e}")
    return f"Error in batch convert to {output_format}: {e}"


async def resize_image(
  ctx: RunContext[EngineContext],
  input_path: str,
  width: int,
  height: int,
  output_path: Optional[str] = None,
  maintain_aspect_ratio: bool = True,
) -> str:
  """
  Resize an image to the specified dimensions.

  Only downscaling is supported — the requested *width* and *height* must both
  be smaller than the original dimensions. Pass either dimension as 0 to derive
  it automatically from the other while maintaining the aspect ratio.

  Args:
      input_path: Path to the input image file.
      width: Target width in pixels (0 = derive from height).
      height: Target height in pixels (0 = derive from width).
      output_path: Path for the resized image. If None, overwrites input file.
      maintain_aspect_ratio: When True (default) and both width and height are
          provided, the image is scaled so it fits within the given box without
          distortion. When False the image is stretched to the exact dimensions.

  Returns:
      Success message with the final dimensions, or an error description.
  """
  try:
    input_p = pathlib.Path(input_path).expanduser().resolve()
    if not input_p.exists() or not input_p.is_file():
      return f"Error: Input file '{input_path}' does not exist or is not a file."

    if width < 0 or height < 0:
      return "Error: width and height must be non-negative integers."
    if width == 0 and height == 0:
      return "Error: at least one of width or height must be greater than zero."

    if output_path is None:
      output_path = str(input_p)
    output_p = pathlib.Path(output_path).expanduser().resolve()
    output_p.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(input_p) as img:
      orig_w, orig_h = img.size
      original_format = img.format or 'PNG'

      # Derive missing dimension
      if width == 0:
        scale = height / orig_h
        width = int(orig_w * scale)
      elif height == 0:
        scale = width / orig_w
        height = int(orig_h * scale)
      elif maintain_aspect_ratio:
        scale = min(width / orig_w, height / orig_h)
        width = int(orig_w * scale)
        height = int(orig_h * scale)

      # Enforce downscale-only
      if width > orig_w or height > orig_h:
        return (
          f"Error: Upscaling is not supported. "
          f"Requested {width}\u00d7{height} is larger than the original "
          f"{orig_w}\u00d7{orig_h}."
        )

      resized = img.resize((width, height), Image.Resampling.LANCZOS)
      resized.save(output_p, format=original_format)

    return (
      f"Successfully resized '{input_path}' to {width}\u00d7{height} "
      f"and saved to '{output_path}'."
    )

  except Exception as e:
    logger.error(f"Error resizing image: {e}")
    return f"Error resizing image: {e}"


async def batch_resize_images(
  ctx: RunContext[EngineContext],
  src_directory: str = ".",
  dest_directory: str = "resized",
  width: int = 0,
  height: int = 0,
  maintain_aspect_ratio: bool = True,
) -> str:
  """
  Resize all images in a source directory and save to destination directory.

  Only downscaling is supported. See resize_image() for dimension rules.

  Args:
      src_directory: Source directory path.
      dest_directory: Destination directory path.
      width: Target width in pixels (0 = derive from height).
      height: Target height in pixels (0 = derive from width).
      maintain_aspect_ratio: Preserve aspect ratio when both dimensions are given.

  Returns:
      Summary of operations.
  """
  try:
    src_p = pathlib.Path(src_directory).expanduser().resolve()
    dest_p = pathlib.Path(dest_directory).expanduser().resolve()
    dest_p.mkdir(parents=True, exist_ok=True)

    supported_formats = (".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".gif", ".webp", ".ico")
    processed = 0
    errors = []

    for filename in os.listdir(src_p):
      if filename.lower().endswith(supported_formats):
        input_path = src_p / filename
        output_path = dest_p / filename
        result = await resize_image(
          ctx, str(input_path), width, height,
          str(output_path), maintain_aspect_ratio
        )
        if "Successfully" in result:
          processed += 1
        else:
          errors.append(f"{filename}: {result}")

    result = f"Resized {processed} images."
    if errors:
      result += f" Errors: {', '.join(errors)}"
    return result

  except Exception as e:
    logger.error(f"Error in batch resize: {e}")
    return f"Error in batch resize: {e}"


TOOLS = [
  optimize_image,
  convert_image,
  resize_image,
  batch_optimize_images,
  batch_convert_image,
  batch_resize_images,
]
