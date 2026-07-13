"""
Property-based and example tests for the ``SystemInformationService`` probe
guard and VRAM normalization helper (spec: system-information-context, task 2.1).

Covered correctness property (see design.md):
  - Property 3 (VRAM normalization): the stored ``total_vram_bytes`` equals
    ``UNKNOWN`` if and only if the raw reading is missing, non-numeric, or
    numerically zero; any strictly positive reading is preserved as its byte
    value string.

Example tests additionally cover ``_safe``: error/timeout guarding and the
normalization of ``None``/blank results to ``UNKNOWN``.
"""

import time

from hypothesis import given, settings, strategies as st

from subconscious.system_info import UNKNOWN, SystemInformationService


def _service() -> SystemInformationService:
  """A service instance; helper behaviour is independent of ``data_dir``."""
  return SystemInformationService(data_dir="")


def _is_strictly_positive_int(raw) -> bool:
  """Independent oracle: is ``raw`` a strictly positive integer reading?"""
  if raw is None:
    return False
  try:
    return int(str(raw).strip()) > 0
  except (TypeError, ValueError):
    return False


# ---------------------------------------------------------------------------
# Property 3: VRAM normalization
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 3: For any raw VRAM reading, the
# stored total_vram_bytes equals "unknown" if and only if the reading is
# missing, non-numeric, or numerically zero; any strictly positive reading is
# preserved as its byte value.
# Validates: Requirements 1.2, 1.3
@settings(max_examples=100, deadline=None)
@given(
  raw=st.one_of(
    st.none(),                    # missing
    st.text(max_size=24),         # "" and arbitrary non-numeric (occasionally numeric) text
    st.integers(),                # 0, negatives, and positive ints
    st.integers(min_value=1),     # bias toward strictly positive readings
  )
)
def test_vram_normalization_unknown_iff_not_strictly_positive(raw):
  result = SystemInformationService._normalize_vram(raw)

  if _is_strictly_positive_int(raw):
    # Strictly positive reading is preserved exactly as its byte-value string.
    assert result == str(int(str(raw).strip()))
  else:
    # Missing, non-numeric, zero, or negative -> UNKNOWN.
    assert result == UNKNOWN


# ---------------------------------------------------------------------------
# Example tests — VRAM normalization edge cases
# ---------------------------------------------------------------------------

class TestVramNormalizationExamples:
  def test_none_is_unknown(self):
    assert SystemInformationService._normalize_vram(None) == UNKNOWN

  def test_empty_string_is_unknown(self):
    assert SystemInformationService._normalize_vram("") == UNKNOWN

  def test_non_numeric_is_unknown(self):
    assert SystemInformationService._normalize_vram("N/A") == UNKNOWN

  def test_zero_is_unknown(self):
    assert SystemInformationService._normalize_vram(0) == UNKNOWN
    assert SystemInformationService._normalize_vram("0") == UNKNOWN

  def test_negative_is_unknown(self):
    assert SystemInformationService._normalize_vram(-1) == UNKNOWN

  def test_positive_int_preserved_as_string(self):
    assert SystemInformationService._normalize_vram(10737418240) == "10737418240"

  def test_positive_numeric_string_preserved_canonically(self):
    assert SystemInformationService._normalize_vram(" 8589934592 ") == "8589934592"

  def test_large_value_preserved_exactly(self):
    huge = 10 ** 30
    assert SystemInformationService._normalize_vram(huge) == str(huge)


# ---------------------------------------------------------------------------
# Example tests — _safe probe guard
# ---------------------------------------------------------------------------

class TestSafeProbeGuard:
  def test_successful_probe_value_stripped(self):
    assert _service()._safe(lambda: "  x86_64  ") == "x86_64"

  def test_probe_raising_returns_unknown(self):
    def boom() -> str:
      raise RuntimeError("probe blew up")

    assert _service()._safe(boom) == UNKNOWN

  def test_none_result_is_unknown(self):
    assert _service()._safe(lambda: None) == UNKNOWN

  def test_blank_result_is_unknown(self):
    assert _service()._safe(lambda: "   ") == UNKNOWN

  def test_non_string_result_coerced_to_string(self):
    assert _service()._safe(lambda: 24) == "24"

  def test_timeout_returns_unknown(self):
    def slow() -> str:
      time.sleep(1.0)
      return "too late"

    assert _service()._safe(slow, timeout=0.05) == UNKNOWN

  def test_fast_probe_under_timeout_returns_value(self):
    assert _service()._safe(lambda: "quick", timeout=1.0) == "quick"
