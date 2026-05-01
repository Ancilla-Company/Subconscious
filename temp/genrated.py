import flet as ft
import uuid

"""
Pure-Python GitHub-style identicon generator.

Produces a symmetric 5×5 grid SVG (as a data-URI string) from any seed string.
No external dependencies — uses only hashlib from the standard library.

Usage:
  from .identicon import identicon_data_uri
  svg_uri = identicon_data_uri("some-seed-string")
  # Pass to ft.Image(src=svg_uri)
"""
import hashlib


def identicon_data_uri(seed: str, size: int = 40, padding: int = 5) -> str:
  """
  Generate a GitHub-style identicon SVG data-URI from a seed string.

  The algorithm mirrors GitHub's approach:
    - MD5 hash of the seed (lowercased).
    - Bytes 0–14 → 15 cells of a 5×5 left-right-symmetric grid.
      Each cell is filled if the byte value is odd.
    - Bytes 15–16 → hue (0–360) derived from two bytes.
    - Saturation fixed at 65%, lightness at 55% (matches GitHub's palette).

  Args:
    seed:    Any string — username, UUID, etc.
    size:    Output SVG size in px (both width and height).
    padding: Inner whitespace around the grid in px.

  Returns:
    A ``data:image/svg+xml,...`` URI safe to pass to ``ft.Image(src=...)``.
  """
  digest = hashlib.md5(seed.lower().encode("utf-8")).digest()

  # ── Colour ───────────────────────────────────────────────────────────
  # MD5 = 16 bytes (indices 0–15). Use bytes 14 & 15 for hue.
  hue = ((digest[14] << 8) | digest[15]) % 360
  colour = f"hsl({hue}, 65%, 55%)"
  bg = "transparent"

  # ── Grid ─────────────────────────────────────────────────────────────
  # 5 columns × 5 rows = 25 cells.
  # Only the left 3 columns are independent (bytes 0–12, one per unique cell).
  # Columns 3 and 4 mirror columns 1 and 0 respectively.
  # Bytes 13–15 are reserved for colour above.
  grid_size = size - 2 * padding
  cell_w = grid_size / 5
  cell_h = grid_size / 5

  rects: list[str] = []
  byte_idx = 0
  for row in range(5):
    for col in range(3):           # only generate left half + centre
      filled = (digest[byte_idx] % 2) == 1
      byte_idx += 1
      if not filled:
        continue
      # Mirror: columns 0,1,2,3,4 → indices 0,1,2,1,0
      mirror_cols = [0, 1, 2, 1, 0]
      # Current col maps to these grid columns:
      grid_cols = [c for c in range(5) if mirror_cols[c] == col]
      for gc in grid_cols:
        x = padding + gc * cell_w
        y = padding + row * cell_h
        rects.append(
          f'<rect x="{x:.2f}" y="{y:.2f}" '
          f'width="{cell_w:.2f}" height="{cell_h:.2f}" '
          f'fill="{colour}" rx="1"/>'
        )

  rects_svg = "".join(rects)
  svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" '
    f'width="{size}" height="{size}" viewBox="0 0 {size} {size}">'
    f'<rect width="{size}" height="{size}" fill="{bg}"/>'
    f'{rects_svg}'
    f'</svg>'
  )

  # Base64-encode the SVG for Flet compatibility
  import base64
  b64 = base64.b64encode(svg.encode("utf-8")).decode("utf-8")
  return f"data:image/svg+xml;base64,{b64}"


def main(page: ft.Page):
  page.theme_mode = ft.ThemeMode.LIGHT
  page.add(
    ft.Container(
      ft.Image(
        src=identicon_data_uri(str(uuid.uuid4()), size=40, padding=0),
        width=40,
        height=40,
      ),
      border=ft.Border.all(width=1),
      border_radius=ft.BorderRadius(4,4,4,4),
      padding=ft.Padding.all(0),
      bgcolor=ft.Colors.RED


    )
  )
  page.add(ft.Text("Hi", size=25))
  page.update()

ft.run(main)