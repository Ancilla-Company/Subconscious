"""
Unit tests for subconscious.tools.calculator
"""

import pytest
from subconscious.tools.calculator import calculate, convert_units, list_supported_units
# pytest already imported above


# ---------------------------------------------------------------------------
# calculate — basic arithmetic
# ---------------------------------------------------------------------------

async def test_calculate_addition(ctx):
  assert await calculate(ctx, "2 + 2") == "4"

async def test_calculate_subtraction(ctx):
  assert await calculate(ctx, "10 - 3") == "7"

async def test_calculate_multiplication(ctx):
  assert await calculate(ctx, "6 * 7") == "42"

async def test_calculate_division(ctx):
  assert await calculate(ctx, "10 / 4") == "2.5"

async def test_calculate_floor_division(ctx):
  assert await calculate(ctx, "10 // 3") == "3"

async def test_calculate_modulo(ctx):
  assert await calculate(ctx, "10 % 3") == "1"

async def test_calculate_exponent(ctx):
  assert await calculate(ctx, "2 ** 10") == "1024"

async def test_calculate_negative_unary(ctx):
  assert await calculate(ctx, "-5 + 3") == "-2"


# ---------------------------------------------------------------------------
# calculate — math functions
# ---------------------------------------------------------------------------

async def test_calculate_sqrt(ctx):
  assert await calculate(ctx, "sqrt(144)") == "12"

async def test_calculate_sin(ctx):
  result = await calculate(ctx, "sin(0)")
  assert result == "0"

async def test_calculate_pi_constant(ctx):
  result = await calculate(ctx, "pi")
  assert result.startswith("3.14")

async def test_calculate_factorial(ctx):
  assert await calculate(ctx, "factorial(6)") == "720"

async def test_calculate_log(ctx):
  result = await calculate(ctx, "log(1000, 10)")
  # log(1000, 10) has a floating-point representation; accept '3' or '3.0' or close float
  assert float(result) == pytest.approx(3.0, rel=1e-9)

async def test_calculate_abs(ctx):
  assert await calculate(ctx, "abs(-99)") == "99"

async def test_calculate_round(ctx):
  assert await calculate(ctx, "round(3.7)") == "4"


# ---------------------------------------------------------------------------
# calculate — security / error cases
# ---------------------------------------------------------------------------

async def test_calculate_division_by_zero(ctx):
  result = await calculate(ctx, "1 / 0")
  assert "division by zero" in result.lower()

async def test_calculate_unsupported_builtin(ctx):
  result = await calculate(ctx, "__import__('os')")
  assert "Error" in result or "Unsupported" in result

async def test_calculate_string_not_allowed(ctx):
  result = await calculate(ctx, "'hello'")
  assert "Error" in result or "Unsupported" in result

async def test_calculate_exec_not_allowed(ctx):
  result = await calculate(ctx, "exec('import os')")
  assert "Error" in result or "Unsupported" in result


# ---------------------------------------------------------------------------
# convert_units
# ---------------------------------------------------------------------------

async def test_convert_km_to_miles(ctx):
  result = await convert_units(ctx, 1.0, "km", "mi")
  assert "0.621" in result

async def test_convert_kg_to_lbs(ctx):
  result = await convert_units(ctx, 1.0, "kg", "lb")
  assert "2.20" in result

async def test_convert_celsius_to_fahrenheit(ctx):
  result = await convert_units(ctx, 100.0, "C", "F")
  assert "212" in result

async def test_convert_fahrenheit_to_celsius(ctx):
  result = await convert_units(ctx, 32.0, "F", "C")
  assert "0" in result

async def test_convert_celsius_to_kelvin(ctx):
  result = await convert_units(ctx, 0.0, "C", "K")
  assert "273.15" in result

async def test_convert_bytes_to_megabytes(ctx):
  result = await convert_units(ctx, 1048576.0, "b", "mb")
  assert "1" in result

async def test_convert_unknown_unit(ctx):
  result = await convert_units(ctx, 1.0, "furlongs", "parsecs")
  assert "Unknown" in result or "not supported" in result.lower()

async def test_convert_mismatched_categories(ctx):
  result = await convert_units(ctx, 1.0, "km", "kg")
  assert "Cannot convert" in result or "different" in result.lower()


# ---------------------------------------------------------------------------
# list_supported_units
# ---------------------------------------------------------------------------

async def test_list_supported_units_returns_dict(ctx):
  result = await list_supported_units(ctx)
  assert isinstance(result, dict)
  assert "length" in result
  assert "mass" in result

async def test_list_supported_units_length_has_km(ctx):
  result = await list_supported_units(ctx)
  assert "km" in result.get("length", [])
