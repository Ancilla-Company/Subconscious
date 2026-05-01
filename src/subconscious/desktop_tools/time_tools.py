"""
Time tools — clock, date, timezone conversion.
No external dependencies beyond the standard library.
"""

from . import EngineContext
from datetime import datetime
from pydantic_ai import RunContext
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


async def get_current_time(ctx: RunContext[EngineContext], tz: str = "UTC") -> str:
  """
  Return the current time in the given IANA timezone (e.g. 'America/New_York').
  Defaults to UTC. Returns an ISO-8601 formatted string including timezone offset.
  """
  try:
    zone = ZoneInfo(tz)
  except ZoneInfoNotFoundError:
    return f"Unknown timezone '{tz}'. Use an IANA name like 'Europe/London' or 'America/Chicago'."
  now = datetime.now(zone)
  return now.strftime(f"%Y-%m-%d %H:%M:%S %Z (UTC%z)")


async def get_current_date(ctx: RunContext[EngineContext], tz: str = "UTC") -> str:
  """
  Return today's date (year, month, day, weekday) in the given IANA timezone.
  Defaults to UTC.
  """
  try:
    zone = ZoneInfo(tz)
  except ZoneInfoNotFoundError:
    return f"Unknown timezone '{tz}'."
  today = datetime.now(zone)
  return today.strftime("%A, %d %B %Y")


async def convert_timezone(
  ctx: RunContext[EngineContext],
  time_str: str,
  from_tz: str,
  to_tz: str,
) -> str:
  """
  Convert a time expressed as 'HH:MM' or 'YYYY-MM-DD HH:MM' from one IANA
  timezone to another.  Returns the converted time as a human-readable string.

  Args:
    time_str: Time to convert, e.g. '14:30' or '2026-03-16 14:30'.
    from_tz:  Source IANA timezone, e.g. 'America/New_York'.
    to_tz:    Target IANA timezone, e.g. 'Asia/Tokyo'.
  """
  for fmt in ("%Y-%m-%d %H:%M", "%H:%M"):
    try:
      naive = datetime.strptime(time_str, fmt)
      break
    except ValueError:
      pass
  else:
    return f"Could not parse '{time_str}'. Use 'HH:MM' or 'YYYY-MM-DD HH:MM'."

  try:
    src_zone = ZoneInfo(from_tz)
    dst_zone = ZoneInfo(to_tz)
  except ZoneInfoNotFoundError as exc:
    return f"Unknown timezone: {exc}"

  aware = naive.replace(tzinfo=src_zone)
  converted = aware.astimezone(dst_zone)
  return converted.strftime(f"%Y-%m-%d %H:%M %Z (UTC%z)")


async def list_common_timezones(ctx: RunContext[EngineContext]) -> list[str]:
  """
  Return a list of commonly used IANA timezone names for reference.
  """
  return [
    "UTC",
    "America/New_York", "America/Chicago", "America/Denver",
    "America/Los_Angeles", "America/Toronto", "America/Sao_Paulo",
    "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Moscow",
    "Africa/Johannesburg", "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore",
    "Asia/Tokyo", "Asia/Shanghai", "Australia/Sydney", "Pacific/Auckland",
  ]


TOOLS = [get_current_time, get_current_date, convert_timezone, list_common_timezones]
