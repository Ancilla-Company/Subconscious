"""
Property-based and example tests for ``SystemInformationService`` ambient
context formatting and GB conversion (spec: system-information-context, task 6.1).

Covered correctness properties (see design.md):
  - Property 7 (GB conversion): for any strictly positive byte value among the
    byte-valued metrics (total RAM, total VRAM), the formatted ambient context
    expresses it as ``bytes / 1_000_000_000`` rounded to one decimal place with
    a ``GB`` unit; a byte metric whose value is ``UNKNOWN`` is rendered
    literally as ``unknown`` with no unit.
  - Property 8 (Human-readable rendering): for any ``SystemProfile``, the string
    produced by ``format_ambient_context()`` is non-empty and contains a
    rendering of every Static and OS metric field.

The profile is injected directly into the service so the tests never depend on
real host hardware.
"""

from dataclasses import fields

from hypothesis import given, settings, strategies as st

from subconscious.system_info import (
  UNKNOWN,
  OSMetrics,
  StaticMetrics,
  SystemInformationService,
  SystemProfile,
)


def _service_with_profile(profile: SystemProfile) -> SystemInformationService:
  """A service whose in-memory profile is pre-seeded, so formatting reads it
  directly without any file access or collection."""
  svc = SystemInformationService(data_dir="")
  svc._profile = profile
  return svc


def _expected_gb(byte_value: int) -> str:
  """Independent oracle for the GB rendering of a positive byte value."""
  return f"{byte_value / 1_000_000_000:.1f} GB"


# Byte-valued fields are either UNKNOWN or a strictly positive byte count.
_byte_field = st.one_of(
  st.just(UNKNOWN),
  st.integers(min_value=1, max_value=2 ** 60).map(str),
)
# Non-byte fields are arbitrary short text (no control chars) or UNKNOWN.
_text_field = st.one_of(
  st.just(UNKNOWN),
  st.text(
    alphabet=st.characters(min_codepoint=32, max_codepoint=126),
    max_size=40,
  ),
)


@st.composite
def _system_profiles(draw) -> SystemProfile:
  static = StaticMetrics(
    cpu_model=draw(_text_field),
    physical_cores=draw(_text_field),
    logical_cores=draw(_text_field),
    total_ram_bytes=draw(_byte_field),
    cpu_architecture=draw(_text_field),
    gpu_model=draw(_text_field),
    total_vram_bytes=draw(_byte_field),
    accelerator=draw(_text_field),
  )
  os_metrics = OSMetrics(
    os_name=draw(_text_field),
    os_version=draw(_text_field),
    machine_architecture=draw(_text_field),
    python_version=draw(_text_field),
  )
  return SystemProfile(static=static, os=os_metrics)


# ---------------------------------------------------------------------------
# Property 7: GB conversion
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 7: For any strictly positive
# byte value among the byte-valued metrics (total RAM, total VRAM), the
# formatted ambient context expresses it as a gigabyte figure equal to
# bytes / 1_000_000_000 rounded to one decimal place with a GB unit; a byte
# metric whose value is "unknown" is rendered literally as "unknown" with no
# unit.
# Validates: Requirements 6.3
@settings(max_examples=100, deadline=None)
@given(
  ram=st.one_of(st.just(UNKNOWN), st.integers(min_value=1, max_value=2 ** 60)),
  vram=st.one_of(st.just(UNKNOWN), st.integers(min_value=1, max_value=2 ** 60)),
)
def test_gb_conversion_in_ambient_context(ram, vram):
  ram_field = ram if ram == UNKNOWN else str(ram)
  vram_field = vram if vram == UNKNOWN else str(vram)
  profile = SystemProfile(
    static=StaticMetrics(total_ram_bytes=ram_field, total_vram_bytes=vram_field),
    os=OSMetrics(),
  )
  output = _service_with_profile(profile).format_ambient_context()

  if ram == UNKNOWN:
    assert f"Total RAM: {UNKNOWN}" in output
  else:
    assert f"Total RAM: {_expected_gb(ram)}" in output

  if vram == UNKNOWN:
    assert f"Total VRAM: {UNKNOWN}" in output
  else:
    assert f"Total VRAM: {_expected_gb(vram)}" in output


# ---------------------------------------------------------------------------
# Property 8: Human-readable rendering
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 8: For any SystemProfile, the
# string produced by format_ambient_context() is non-empty and contains a
# rendering of every Static and OS metric field (each field's value, or
# "unknown" when the field is unknown).
# Validates: Requirements 6.2
@settings(max_examples=100, deadline=None)
@given(profile=_system_profiles())
def test_human_readable_rendering_contains_every_field(profile):
  svc = _service_with_profile(profile)

  output = svc.format_ambient_context()

  # Non-empty and wrapped in the system_information block.
  assert output
  assert "<system_information>" in output
  assert "</system_information>" in output

  byte_field_names = {"total_ram_bytes", "total_vram_bytes"}

  # Every Static field is rendered: byte fields via GB conversion, others
  # verbatim (or "unknown").
  for f in fields(profile.static):
    value = getattr(profile.static, f.name)
    if f.name in byte_field_names:
      expected = SystemInformationService._format_bytes_as_gb(value)
    else:
      expected = value
    assert expected in output, f"static.{f.name} rendering {expected!r} missing"

  # Every OS field is rendered verbatim (or "unknown").
  for f in fields(profile.os):
    value = getattr(profile.os, f.name)
    assert value in output, f"os.{f.name} value {value!r} missing"


# ---------------------------------------------------------------------------
# Example tests — GB conversion helper
# ---------------------------------------------------------------------------

class TestGbConversionExamples:
  def test_unknown_renders_literally(self):
    assert SystemInformationService._format_bytes_as_gb(UNKNOWN) == UNKNOWN

  def test_non_numeric_renders_as_unknown(self):
    assert SystemInformationService._format_bytes_as_gb("not-a-number") == UNKNOWN

  def test_ram_example_matches_design(self):
    # 34359738368 bytes / 1e9 = 34.359... -> "34.4 GB" (design example).
    assert SystemInformationService._format_bytes_as_gb("34359738368") == "34.4 GB"

  def test_vram_example_matches_design(self):
    # 10737418240 bytes / 1e9 = 10.737... -> "10.7 GB" (design example).
    assert SystemInformationService._format_bytes_as_gb("10737418240") == "10.7 GB"


# ---------------------------------------------------------------------------
# Example tests — full ambient context block
# ---------------------------------------------------------------------------

class TestFormatAmbientContextExamples:
  def _full_profile(self) -> SystemProfile:
    return SystemProfile(
      static=StaticMetrics(
        cpu_model="AMD Ryzen 9 5900X",
        physical_cores="12",
        logical_cores="24",
        total_ram_bytes="34359738368",
        cpu_architecture="x86_64",
        gpu_model="NVIDIA GeForce RTX 3080",
        total_vram_bytes="10737418240",
        accelerator="CUDA",
      ),
      os=OSMetrics(
        os_name="Windows 10",
        os_version="10.0.19045",
        machine_architecture="AMD64",
        python_version="3.12.4",
      ),
    )

  def test_matches_design_example(self):
    output = _service_with_profile(self._full_profile()).format_ambient_context()

    assert "<system_information>" in output
    assert "Operating System: Windows 10 (version 10.0.19045)" in output
    assert "Architecture: AMD64 / x86_64" in output
    assert "Python Runtime: 3.12.4" in output
    assert (
      "CPU: AMD Ryzen 9 5900X (12 physical cores, 24 logical cores)" in output
    )
    assert "Total RAM: 34.4 GB" in output
    assert "GPU: NVIDIA GeForce RTX 3080" in output
    assert "Total VRAM: 10.7 GB" in output
    assert "Accelerator: CUDA" in output
    assert "</system_information>" in output

  def test_all_unknown_profile_shows_unknown_literally(self):
    output = _service_with_profile(
      SystemProfile(static=StaticMetrics(), os=OSMetrics())
    ).format_ambient_context()

    assert output
    assert "Total RAM: unknown" in output
    assert "Total VRAM: unknown" in output
    assert "CPU: unknown (unknown physical cores, unknown logical cores)" in output

  def test_never_raises_returns_empty_on_error(self):
    # A service whose get_profile is forced to raise must yield "" not raise.
    svc = SystemInformationService(data_dir="")

    def boom() -> SystemProfile:
      raise RuntimeError("profile resolution blew up")

    svc.get_profile = boom  # type: ignore[assignment]
    assert svc.format_ambient_context() == ""
