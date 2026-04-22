"""
Weather tools — current conditions and forecast via wttr.in (no API key needed).
Requires: httpx
"""

import httpx
import logging
from . import EngineContext
from pydantic_ai import RunContext


logger = logging.getLogger("subconscious")
_TIMEOUT = 10


async def get_weather(ctx: RunContext[EngineContext], location: str) -> dict:
  """
  Get the current weather conditions for a location.
  No API key required — uses the free wttr.in service.

  Args:
    location: City name or 'City, Country', e.g. 'London', 'Paris, FR', 'Tokyo'.
  """
  try:
    encoded = location.replace(" ", "+")
    url = f"https://wttr.in/{encoded}?format=j1"
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
      resp = await client.get(url, headers={"User-Agent": "Subconscious/1.0"})
      resp.raise_for_status()
      data = resp.json()

    current = data["current_condition"][0]
    area    = data["nearest_area"][0]
    area_name = area["areaName"][0]["value"]
    country   = area["country"][0]["value"]

    return {
      "location":        f"{area_name}, {country}",
      "temp_c":          current["temp_C"],
      "temp_f":          current["temp_F"],
      "feels_like_c":    current["FeelsLikeC"],
      "description":     current["weatherDesc"][0]["value"],
      "humidity_pct":    current["humidity"],
      "wind_kmh":        current["windspeedKmph"],
      "wind_direction":  current["winddir16Point"],
      "visibility_km":   current["visibility"],
      "uv_index":        current["uvIndex"],
    }
  except ImportError:
    return {"error": "Required package missing. Install: httpx"}
  except Exception as exc:
    return {"error": f"Could not fetch weather for '{location}': {exc}"}


async def get_forecast(ctx: RunContext[EngineContext], location: str, days: int = 3) -> list[dict]:
  """
  Get a multi-day weather forecast for a location (up to 3 days).
  No API key required.

  Args:
    location: City name or 'City, Country'.
    days: Number of days to forecast (1–3, default 3).
  """
  try:
    days = max(1, min(days, 3))
    encoded = location.replace(" ", "+")
    url = f"https://wttr.in/{encoded}?format=j1"
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
      resp = await client.get(url, headers={"User-Agent": "Subconscious/1.0"})
      resp.raise_for_status()
      data = resp.json()

    forecast = []
    for day_data in data.get("weather", [])[:days]:
      forecast.append({
        "date":        day_data["date"],
        "max_temp_c":  day_data["maxtempC"],
        "min_temp_c":  day_data["mintempC"],
        "max_temp_f":  day_data["maxtempF"],
        "min_temp_f":  day_data["mintempF"],
        "description": day_data["hourly"][4]["weatherDesc"][0]["value"],  # midday
        "sunrise":     day_data["astronomy"][0]["sunrise"],
        "sunset":      day_data["astronomy"][0]["sunset"],
      })
    return forecast
  except ImportError:
    return [{"error": "Required package missing. Install: httpx"}]
  except Exception as exc:
    return [{"error": f"Could not fetch forecast for '{location}': {exc}"}]


TOOLS = [get_weather, get_forecast]
