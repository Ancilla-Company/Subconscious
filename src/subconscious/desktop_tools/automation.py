"""
Desktop automation tools — control the mouse and keyboard and inspect the
screen using PyAutoGUI.

Requires: pyautogui  (pip install pyautogui)

These tools drive the local machine's input devices, so every action that moves
the pointer, clicks, or types is classified as a *mutation* and is approval
gated by default (see tools.classify_operation). Screen inspection helpers
(size, cursor position, pixel colour, screenshots, image location) are
read-only *queries*.

Safety notes:
  - PyAutoGUI's fail-safe is left enabled: slamming the mouse into a screen
    corner aborts an in-progress automation run.
  - PyAutoGUI is a desktop-only dependency (it needs an active display). The
    module import is guarded so importing it on a headless/unsupported host
    degrades to a clear "unavailable" message instead of crashing the engine.
"""

import asyncio
import logging
import pathlib
from datetime import datetime
from typing import Optional

from pydantic_ai import RunContext

from . import EngineContext


logger = logging.getLogger("subconscious")


# ---------------------------------------------------------------------------
# Optional dependency: pyautogui (needs a display; guard the import)
# ---------------------------------------------------------------------------

try:
  import pyautogui as _pg  # @IgnoreException
  # Keep the fail-safe on (mouse to a corner aborts) and add a tiny pause
  # between calls so automated bursts don't overwhelm the target UI.
  _pg.FAILSAFE = True
  _pg.PAUSE = 0.05
  _PYAUTOGUI_AVAILABLE = True
  _PYAUTOGUI_ERROR = ""
except Exception as exc:  # ImportError, or display/X11 errors on headless hosts
  _pg = None  # type: ignore[assignment]
  _PYAUTOGUI_AVAILABLE = False
  _PYAUTOGUI_ERROR = str(exc)


_UNAVAILABLE_MSG = (
  "Desktop automation is unavailable: PyAutoGUI could not be loaded "
  "({reason}). Install it with 'pip install pyautogui' and ensure the process "
  "has access to an active display."
)


def _unavailable() -> str:
  return _UNAVAILABLE_MSG.format(reason=_PYAUTOGUI_ERROR or "not installed")


# Valid mouse buttons accepted by pyautogui.
_BUTTONS = {"left", "middle", "right"}


# ---------------------------------------------------------------------------
# Screen inspection (queries)
# ---------------------------------------------------------------------------

async def get_screen_size(ctx: RunContext[EngineContext]) -> str:
  """
  Return the primary screen resolution as "WIDTHxHEIGHT" in pixels.
  Useful before moving the mouse or clicking so coordinates stay on-screen.
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    size = await asyncio.to_thread(_pg.size)
    return f"Screen size: {size.width}x{size.height} pixels."
  except Exception as exc:
    return f"Error getting screen size: {exc}"


async def get_mouse_position(ctx: RunContext[EngineContext]) -> str:
  """
  Return the current mouse cursor position as "x=<X>, y=<Y>" in screen pixels.
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    pos = await asyncio.to_thread(_pg.position)
    return f"Mouse position: x={pos.x}, y={pos.y}"
  except Exception as exc:
    return f"Error getting mouse position: {exc}"


async def get_pixel_color(ctx: RunContext[EngineContext], x: int, y: int) -> str:
  """
  Return the RGB colour of the screen pixel at (x, y).

  Args:
    x: Horizontal pixel coordinate (0 = left edge).
    y: Vertical pixel coordinate (0 = top edge).
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    rgb = await asyncio.to_thread(_pg.pixel, int(x), int(y))
    return f"Pixel ({x}, {y}) colour: RGB{tuple(rgb)} (#{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x})"
  except Exception as exc:
    return f"Error reading pixel colour: {exc}"


async def capture_screenshot(
  ctx: RunContext[EngineContext],
  output_path: Optional[str] = None,
  region: Optional[list[int]] = None,
) -> str:
  """
  Capture a screenshot of the whole screen (or a rectangular region) and save
  it as a PNG. Returns the saved file path.

  Args:
    output_path: Destination .png path. When omitted the image is saved under
      the app data directory's "screenshots" folder with a timestamped name.
    region: Optional [left, top, width, height] to capture only part of the
      screen. When omitted the full screen is captured.
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    if output_path:
      out = pathlib.Path(output_path).expanduser().resolve()
    else:
      base = pathlib.Path(ctx.deps.data_dir or ".").expanduser().resolve() / "screenshots"
      out = base / f"screenshot_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
    out.parent.mkdir(parents=True, exist_ok=True)

    reg = None
    if region is not None:
      if len(region) != 4:
        return "Error: region must be [left, top, width, height]."
      reg = tuple(int(v) for v in region)

    def _shot():
      img = _pg.screenshot(region=reg)
      img.save(str(out))

    await asyncio.to_thread(_shot)
    return f"Screenshot saved to '{out}'."
  except Exception as exc:
    return f"Error capturing screenshot: {exc}"


async def locate_on_screen(
  ctx: RunContext[EngineContext],
  image_path: str,
  confidence: float = 0.9,
) -> str:
  """
  Locate a reference image on the current screen and return the centre
  coordinates of the first match, suitable for a subsequent click.

  Args:
    image_path: Path to the reference image (PNG/JPG) to search for.
    confidence: Match tolerance from 0.1 to 1.0 (default 0.9). Values below 1.0
      require OpenCV (pip install opencv-python); without it an exact match is
      attempted instead.
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    img_p = pathlib.Path(image_path).expanduser().resolve()
    if not img_p.exists() or not img_p.is_file():
      return f"Error: reference image '{image_path}' does not exist."

    def _locate():
      try:
        return _pg.locateCenterOnScreen(str(img_p), confidence=confidence)
      except TypeError:
        # OpenCV missing → confidence unsupported; fall back to exact match.
        return _pg.locateCenterOnScreen(str(img_p))

    point = await asyncio.to_thread(_locate)
    if point is None:
      return f"Image '{image_path}' was not found on screen."
    return f"Found '{img_p.name}' at x={int(point.x)}, y={int(point.y)}."
  except Exception as exc:
    return f"Error locating image on screen: {exc}"


# ---------------------------------------------------------------------------
# Mouse control (mutations)
# ---------------------------------------------------------------------------

async def move_mouse(
  ctx: RunContext[EngineContext],
  x: int,
  y: int,
  duration: float = 0.2,
) -> str:
  """
  Move the mouse cursor to absolute screen coordinates (x, y).

  Args:
    x: Target horizontal pixel coordinate.
    y: Target vertical pixel coordinate.
    duration: Seconds spent gliding to the target (default 0.2, 0 = instant).
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    await asyncio.to_thread(_pg.moveTo, int(x), int(y), max(0.0, float(duration)))
    return f"Moved mouse to x={x}, y={y}."
  except Exception as exc:
    return f"Error moving mouse: {exc}"


async def click_mouse(
  ctx: RunContext[EngineContext],
  x: Optional[int] = None,
  y: Optional[int] = None,
  button: str = "left",
  clicks: int = 1,
) -> str:
  """
  Click the mouse, optionally moving to (x, y) first.

  Args:
    x: Horizontal coordinate to click at. When omitted the current position is used.
    y: Vertical coordinate to click at. When omitted the current position is used.
    button: "left", "middle", or "right" (default "left").
    clicks: Number of clicks to perform (default 1).
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  btn = button.lower().strip()
  if btn not in _BUTTONS:
    return f"Error: button must be one of {sorted(_BUTTONS)}."
  if clicks < 1:
    return "Error: clicks must be at least 1."
  try:
    kwargs: dict = {"button": btn, "clicks": int(clicks)}
    if x is not None and y is not None:
      kwargs["x"], kwargs["y"] = int(x), int(y)
    await asyncio.to_thread(lambda: _pg.click(**kwargs))
    where = f" at x={x}, y={y}" if x is not None and y is not None else ""
    return f"Performed {clicks}x {btn} click{'s' if clicks > 1 else ''}{where}."
  except Exception as exc:
    return f"Error clicking mouse: {exc}"


async def double_click_mouse(
  ctx: RunContext[EngineContext],
  x: Optional[int] = None,
  y: Optional[int] = None,
  button: str = "left",
) -> str:
  """
  Double-click the mouse, optionally moving to (x, y) first.

  Args:
    x: Horizontal coordinate. When omitted the current position is used.
    y: Vertical coordinate. When omitted the current position is used.
    button: "left", "middle", or "right" (default "left").
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  btn = button.lower().strip()
  if btn not in _BUTTONS:
    return f"Error: button must be one of {sorted(_BUTTONS)}."
  try:
    kwargs: dict = {"button": btn}
    if x is not None and y is not None:
      kwargs["x"], kwargs["y"] = int(x), int(y)
    await asyncio.to_thread(lambda: _pg.doubleClick(**kwargs))
    where = f" at x={x}, y={y}" if x is not None and y is not None else ""
    return f"Double-clicked ({btn}){where}."
  except Exception as exc:
    return f"Error double-clicking mouse: {exc}"


async def drag_mouse(
  ctx: RunContext[EngineContext],
  x: int,
  y: int,
  button: str = "left",
  duration: float = 0.3,
) -> str:
  """
  Press and hold a mouse button and drag from the current cursor position to
  the target (x, y), then release.

  Args:
    x: Destination horizontal coordinate.
    y: Destination vertical coordinate.
    button: "left", "middle", or "right" (default "left").
    duration: Seconds spent dragging (default 0.3).
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  btn = button.lower().strip()
  if btn not in _BUTTONS:
    return f"Error: button must be one of {sorted(_BUTTONS)}."
  try:
    await asyncio.to_thread(_pg.dragTo, int(x), int(y), max(0.0, float(duration)), button=btn)
    return f"Dragged to x={x}, y={y} with {btn} button."
  except Exception as exc:
    return f"Error dragging mouse: {exc}"


async def scroll_mouse(ctx: RunContext[EngineContext], amount: int) -> str:
  """
  Scroll the mouse wheel vertically. Positive scrolls up, negative scrolls down.

  Args:
    amount: Number of scroll "clicks" (e.g. 3 to scroll up, -3 to scroll down).
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    await asyncio.to_thread(_pg.scroll, int(amount))
    direction = "up" if amount >= 0 else "down"
    return f"Scrolled {direction} by {abs(int(amount))}."
  except Exception as exc:
    return f"Error scrolling: {exc}"


# ---------------------------------------------------------------------------
# Keyboard control (mutations)
# ---------------------------------------------------------------------------

async def type_text(
  ctx: RunContext[EngineContext],
  text: str,
  interval: float = 0.0,
) -> str:
  """
  Type a string as if entered on the keyboard, into whatever currently has
  focus.

  Args:
    text: The text to type.
    interval: Seconds to wait between each character (default 0 = as fast as
      possible). A small value like 0.02 helps slower target apps keep up.
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  try:
    await asyncio.to_thread(_pg.write, text, interval=max(0.0, float(interval)))
    preview = text[:60] + ("…" if len(text) > 60 else "")
    return f"Typed {len(text)} characters: {preview}"
  except Exception as exc:
    return f"Error typing text: {exc}"


async def press_key(ctx: RunContext[EngineContext], key: str, presses: int = 1) -> str:
  """
  Press a single named key one or more times (e.g. "enter", "tab", "esc",
  "up", "f5", "a").

  Args:
    key: The key name as understood by PyAutoGUI (see its KEYBOARD_KEYS list).
    presses: How many times to press the key (default 1).
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  if presses < 1:
    return "Error: presses must be at least 1."
  key = key.strip()
  valid_keys = getattr(_pg, "KEYBOARD_KEYS", None)
  if valid_keys and key.lower() not in valid_keys:
    return f"Error: unknown key '{key}'. Use a PyAutoGUI key name like 'enter', 'tab', or 'f5'."
  try:
    await asyncio.to_thread(_pg.press, key.lower(), presses=int(presses))
    return f"Pressed '{key}' {presses} time{'s' if presses > 1 else ''}."
  except Exception as exc:
    return f"Error pressing key: {exc}"


async def press_hotkey(ctx: RunContext[EngineContext], keys: list[str]) -> str:
  """
  Press a keyboard combination (hotkey) with modifiers held together, e.g.
  ["ctrl", "c"] to copy or ["alt", "tab"] to switch windows.

  Args:
    keys: Ordered list of key names to press simultaneously. Modifiers first,
      e.g. ["ctrl", "shift", "esc"].
  """
  if not _PYAUTOGUI_AVAILABLE:
    return _unavailable()
  if not keys:
    return "Error: provide at least one key, e.g. ['ctrl', 'c']."
  cleaned = [k.strip().lower() for k in keys if k and k.strip()]
  if not cleaned:
    return "Error: no valid keys supplied."
  valid_keys = getattr(_pg, "KEYBOARD_KEYS", None)
  if valid_keys:
    unknown = [k for k in cleaned if k not in valid_keys]
    if unknown:
      return f"Error: unknown key(s) {unknown}. Use PyAutoGUI key names."
  try:
    await asyncio.to_thread(lambda: _pg.hotkey(*cleaned))
    return f"Pressed hotkey: {' + '.join(cleaned)}."
  except Exception as exc:
    return f"Error pressing hotkey: {exc}"


TOOLS = [
  # Screen inspection (queries)
  get_screen_size,
  get_mouse_position,
  get_pixel_color,
  capture_screenshot,
  locate_on_screen,
  # Mouse control (mutations)
  move_mouse,
  click_mouse,
  double_click_mouse,
  drag_mouse,
  scroll_mouse,
  # Keyboard control (mutations)
  type_text,
  press_key,
  press_hotkey,
]
