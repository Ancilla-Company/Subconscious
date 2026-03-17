"""
Calculator tools — safe expression evaluation, unit conversion.
Uses Python's ast module instead of eval() to avoid arbitrary code execution.
"""

import ast
import math
import operator
from typing import Union
from . import EngineContext
from pydantic_ai import RunContext


# ---------------------------------------------------------------------------
# Safe expression evaluator
# ---------------------------------------------------------------------------

_SAFE_OPS = {
  ast.Add:  operator.add,
  ast.Sub:  operator.sub,
  ast.Mult: operator.mul,
  ast.Div:  operator.truediv,
  ast.Pow:  operator.pow,
  ast.Mod:  operator.mod,
  ast.FloorDiv: operator.floordiv,
  ast.USub: operator.neg,
  ast.UAdd: operator.pos,
}

_SAFE_FUNCS = {
  "abs": abs, "round": round,
  "sqrt": math.sqrt, "cbrt": lambda x: x ** (1/3),
  "exp": math.exp, "log": math.log, "log2": math.log2, "log10": math.log10,
  "sin": math.sin, "cos": math.cos, "tan": math.tan,
  "asin": math.asin, "acos": math.acos, "atan": math.atan, "atan2": math.atan2,
  "sinh": math.sinh, "cosh": math.cosh, "tanh": math.tanh,
  "degrees": math.degrees, "radians": math.radians,
  "floor": math.floor, "ceil": math.ceil, "trunc": math.trunc,
  "factorial": math.factorial, "gcd": math.gcd, "lcm": math.lcm,
  "pi": math.pi, "e": math.e, "tau": math.tau, "inf": math.inf,
}


def _eval_node(node: ast.expr) -> Union[int, float]:
  if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
    return node.value
  if isinstance(node, ast.Name) and node.id in _SAFE_FUNCS:
    val = _SAFE_FUNCS[node.id]
    if isinstance(val, (int, float)):
      return val
    raise ValueError(f"'{node.id}' is a function, not a value")
  if isinstance(node, ast.BinOp) and type(node.op) in _SAFE_OPS:
    return _SAFE_OPS[type(node.op)](_eval_node(node.left), _eval_node(node.right))
  if isinstance(node, ast.UnaryOp) and type(node.op) in _SAFE_OPS:
    return _SAFE_OPS[type(node.op)](_eval_node(node.operand))
  if isinstance(node, ast.Call):
    if isinstance(node.func, ast.Name) and node.func.id in _SAFE_FUNCS:
      fn = _SAFE_FUNCS[node.func.id]
      if callable(fn):
        args = [_eval_node(a) for a in node.args]
        return fn(*args)
  raise ValueError(f"Unsupported expression element: {ast.dump(node)}")


# ---------------------------------------------------------------------------
# Unit conversion table (value = factor to SI base unit)
# ---------------------------------------------------------------------------

_UNIT_TABLE: dict[str, tuple[str, float]] = {
  # length (base: metre)
  "mm": ("length", 0.001), "cm": ("length", 0.01), "m": ("length", 1.0),
  "km": ("length", 1000.0), "in": ("length", 0.0254), "ft": ("length", 0.3048),
  "yd": ("length", 0.9144), "mi": ("length", 1609.344), "nmi": ("length", 1852.0),
  # mass (base: kg)
  "mg": ("mass", 1e-6), "g": ("mass", 0.001), "kg": ("mass", 1.0),
  "t": ("mass", 1000.0), "oz": ("mass", 0.02835), "lb": ("mass", 0.45359),
  "st": ("mass", 6.35029),
  # temperature handled separately
  # area (base: m²)
  "mm2": ("area", 1e-6), "cm2": ("area", 1e-4), "m2": ("area", 1.0),
  "km2": ("area", 1e6), "ft2": ("area", 0.0929), "ac": ("area", 4046.86),
  # volume (base: litre)
  "ml": ("volume", 0.001), "l": ("volume", 1.0), "dl": ("volume", 0.1),
  "m3": ("volume", 1000.0), "fl_oz": ("volume", 0.02957), "pt": ("volume", 0.47318),
  "qt": ("volume", 0.94635), "gal": ("volume", 3.78541),
  # speed (base: m/s)
  "m/s": ("speed", 1.0), "km/h": ("speed", 1/3.6), "mph": ("speed", 0.44704),
  "knot": ("speed", 0.51444),
  # data (base: bytes)
  "b": ("data", 1), "kb": ("data", 1024), "mb": ("data", 1024**2),
  "gb": ("data", 1024**3), "tb": ("data", 1024**4),
}


# ---------------------------------------------------------------------------
# Tool functions
# ---------------------------------------------------------------------------

async def calculate(ctx: RunContext[EngineContext], expression: str) -> str:
  """
  Evaluate a mathematical expression and return the result.
  Supports +, -, *, /, **, %, //, and functions like sqrt(), sin(), log(), etc.
  Constants pi, e, tau, inf are also available.

  Examples:
    "2 + 2"                 → "4"
    "sqrt(144)"             → "12.0"
    "sin(radians(30))"      → "0.5"
    "log(1000, 10)"         → "3.0"
    "factorial(6)"          → "720"
  """
  try:
    tree = ast.parse(expression.strip(), mode='eval')
    result = _eval_node(tree.body)
    # Clean up float display
    if isinstance(result, float) and result == int(result) and abs(result) < 1e15:
      return str(int(result))
    return str(result)
  except ZeroDivisionError:
    return "Error: division by zero."
  except Exception as exc:
    return f"Error evaluating expression: {exc}"


async def convert_units(
  ctx: RunContext[EngineContext],
  value: float,
  from_unit: str,
  to_unit: str,
) -> str:
  """
  Convert a numeric value from one unit to another.
  Supported categories: length, mass, area, volume, speed, data.
  Temperature uses special handling (c, f, k).

  Examples:
    value=100, from_unit="km", to_unit="mi"
    value=32,  from_unit="f",  to_unit="c"
    value=5,   from_unit="gb", to_unit="mb"
  """
  fu = from_unit.lower().strip()
  tu = to_unit.lower().strip()

  # Temperature special case
  temp_units = {"c", "f", "k"}
  if fu in temp_units or tu in temp_units:
    return _convert_temperature(value, fu, tu)

  if fu not in _UNIT_TABLE:
    return f"Unknown unit '{from_unit}'."
  if tu not in _UNIT_TABLE:
    return f"Unknown unit '{to_unit}'."

  from_cat, from_factor = _UNIT_TABLE[fu]
  to_cat, to_factor = _UNIT_TABLE[tu]

  if from_cat != to_cat:
    return f"Cannot convert {from_unit} ({from_cat}) to {to_unit} ({to_cat}) — different categories."

  si_value = value * from_factor
  result = si_value / to_factor
  return f"{value} {from_unit} = {round(result, 6)} {to_unit}"


def _convert_temperature(value: float, fu: str, tu: str) -> str:
  # Convert to Celsius first
  if fu == "c":   c = value
  elif fu == "f": c = (value - 32) * 5 / 9
  elif fu == "k": c = value - 273.15
  else: return f"Unknown temperature unit '{fu}'."

  if tu == "c":   result = c
  elif tu == "f": result = c * 9 / 5 + 32
  elif tu == "k": result = c + 273.15
  else: return f"Unknown temperature unit '{tu}'."

  return f"{value}°{fu.upper()} = {round(result, 4)}°{tu.upper()}"


async def list_supported_units(ctx: RunContext[EngineContext]) -> dict[str, list[str]]:
  """
  Return all supported unit abbreviations grouped by category.
  Also lists temperature units: c (Celsius), f (Fahrenheit), k (Kelvin).
  """
  groups: dict[str, list[str]] = {}
  for unit, (cat, _) in _UNIT_TABLE.items():
    groups.setdefault(cat, []).append(unit)
  groups["temperature"] = ["c", "f", "k"]
  return groups


TOOLS = [calculate, convert_units, list_supported_units]
