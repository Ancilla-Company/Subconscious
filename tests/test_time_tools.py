"""
Unit tests for subconscious.tools.time_tools
"""

import re
import pytest
from datetime import datetime

from subconscious.tools.time_tools import (
  get_current_time,
  get_current_date,
  convert_timezone,
  list_common_timezones,
)


# ---------------------------------------------------------------------------
# get_current_time
# ---------------------------------------------------------------------------

async def test_get_current_time_utc(ctx):
  result = await get_current_time(ctx, tz="UTC")
  # Should contain UTC offset +0000
  assert "UTC" in result or "+0000" in result


async def test_get_current_time_named_zone(ctx):
  result = await get_current_time(ctx, tz="America/New_York")
  # Result must be a non-error string with time digits
  assert re.search(r"\d{2}:\d{2}:\d{2}", result), f"Unexpected result: {result}"


async def test_get_current_time_bad_zone(ctx):
  result = await get_current_time(ctx, tz="Mars/Olympus_Mons")
  assert "Unknown timezone" in result


async def test_get_current_time_default_is_utc(ctx):
  result_default = await get_current_time(ctx)
  result_utc     = await get_current_time(ctx, tz="UTC")
  # Both should contain the same hour (within 1-second skew is fine by just comparing hours)
  hour_default = re.search(r"(\d{2}):\d{2}:\d{2}", result_default)
  hour_utc     = re.search(r"(\d{2}):\d{2}:\d{2}", result_utc)
  assert hour_default and hour_utc
  assert hour_default.group(1) == hour_utc.group(1)


# ---------------------------------------------------------------------------
# get_current_date
# ---------------------------------------------------------------------------

async def test_get_current_date_format(ctx):
  result = await get_current_date(ctx, tz="UTC")
  # Should be something like "Sunday, 16 March 2026"
  assert re.search(r"\d{4}", result), f"No year found in: {result}"


async def test_get_current_date_bad_zone(ctx):
  result = await get_current_date(ctx, tz="Fake/Zone")
  assert "Unknown timezone" in result


# ---------------------------------------------------------------------------
# convert_timezone
# ---------------------------------------------------------------------------

async def test_convert_timezone_hhmm(ctx):
  result = await convert_timezone(ctx, "12:00", "UTC", "Asia/Tokyo")
  # Tokyo is UTC+9, so 12:00 UTC → 21:00 JST
  assert "21:00" in result


async def test_convert_timezone_full_datetime(ctx):
  result = await convert_timezone(ctx, "2026-03-16 00:00", "UTC", "America/New_York")
  # UTC midnight → New York (UTC-4 in March DST) = 20:00 the previous day
  assert "2026-03-15" in result or "20:00" in result


async def test_convert_timezone_bad_format(ctx):
  result = await convert_timezone(ctx, "not-a-time", "UTC", "UTC")
  assert "Could not parse" in result


async def test_convert_timezone_bad_zone(ctx):
  result = await convert_timezone(ctx, "12:00", "UTC", "Nowhere/Land")
  assert "Unknown timezone" in result


# ---------------------------------------------------------------------------
# list_common_timezones
# ---------------------------------------------------------------------------

async def test_list_common_timezones_contains_utc(ctx):
  result = await list_common_timezones(ctx)
  assert isinstance(result, list)
  assert "UTC" in result


async def test_list_common_timezones_nonempty(ctx):
  result = await list_common_timezones(ctx)
  assert len(result) >= 10
