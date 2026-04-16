
"""
Image processing tools — convert images to ICO, optimize images, convert to WebP.
Supports various image formats via Pillow (PIL).
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
) -> str:
  """
  Optimize a single image file by resizing to 1024x1024 and saving with compression.

  Supports input/output formats: JPG, JPEG, PNG, BMP, TIFF, GIF, WebP, ICO.

  Args:
      input_path: Path to the input image file.
      output_path: Path for the optimized image. If None, overwrites input file.
      quality: Quality for JPEG/WebP (1-100, default 85).

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
      # Resize to 1024x1024
      optimized = img.resize((1024, 1024), Image.Resampling.LANCZOS)
      original_format = img.format or 'JPEG'

      if original_format.upper() in ('JPEG', 'JPG'):
        optimized.save(output_p, format=original_format, quality=quality, optimize=True)
      elif original_format.upper() == 'PNG':
        optimized.save(output_p, format=original_format, optimize=True)
      elif original_format.upper() == 'ICO':
        # ICO has size limitations, resize to 256x256
        if optimized.mode not in ('RGB', 'RGBA'):
          optimized = optimized.convert('RGBA')
        ico_optimized = optimized.resize((256, 256), Image.Resampling.LANCZOS)
        ico_optimized.save(output_p, format=original_format)
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
) -> str:
  """
  Optimize all images in a source directory and save to destination directory.

  Args:
      src_directory: Source directory path.
      dest_directory: Destination directory path.
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

    for filename in os.listdir(src_p):
      if filename.lower().endswith(supported_formats):
        input_path = src_p / filename
        output_path = dest_p / filename
        try:
          with Image.open(input_path) as img:
            optimized = img.resize((1024, 1024), Image.Resampling.LANCZOS)
            original_format = img.format or 'JPEG'

            if original_format.upper() in ('JPEG', 'JPG'):
              optimized.save(output_path, format=original_format, quality=quality, optimize=True)
            elif original_format.upper() == 'PNG':
              optimized.save(output_path, format=original_format, optimize=True)
            else:
              optimized.save(output_path, format=original_format)
          processed += 1
        except Exception as e:
          errors.append(f"{filename}: {e}")

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


TOOLS = [
  optimize_image,
  convert_image,
  batch_optimize_images,
  batch_convert_image,
]
