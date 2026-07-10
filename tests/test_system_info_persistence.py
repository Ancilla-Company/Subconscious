"""
Property-based and example tests for ``SystemInformationService`` JSON
persistence (spec: system-information-context, task 4.1).

Covered correctness property (see design.md):
  - Property 4 (Persistence round-trip): for any ``SystemProfile``, writing it
    to the ``System_Info_File`` and then reading it back yields an equivalent
    ``SystemProfile`` in which every Static and OS field is preserved.

Example tests additionally cover the load/degradation branches of
``_read_file`` (missing, unreadable, invalid JSON, non-object JSON, unknown
keys, absent fields) and the never-raise contract of ``_write_file``.
"""

import json
import os
from dataclasses import fields

from hypothesis import HealthCheck, given, settings, strategies as st

from subconscious.system_info import (
  UNKNOWN,
  OSMetrics,
  StaticMetrics,
  SystemInformationService,
  SystemProfile,
)


def _service(data_dir: str) -> SystemInformationService:
  return SystemInformationService(data_dir=data_dir)


# Field values are arbitrary strings; UNKNOWN is included explicitly so the
# round-trip is exercised for undetermined metrics too.
_field_value = st.one_of(
  st.just(UNKNOWN),
  st.text(max_size=40),
)


@st.composite
def _system_profiles(draw):
  static = StaticMetrics(
    **{f.name: draw(_field_value) for f in fields(StaticMetrics)}
  )
  os_metrics = OSMetrics(
    **{f.name: draw(_field_value) for f in fields(OSMetrics)}
  )
  return SystemProfile(static=static, os=os_metrics)


# ---------------------------------------------------------------------------
# Property 4: Persistence round-trip
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 4: For any SystemProfile,
# writing it to the System_Info_File and then reading it back yields an
# equivalent SystemProfile in which every Static and OS field is preserved.
# Validates: Requirements 3.1, 3.2, 4.1
@settings(
  max_examples=100,
  deadline=None,
  suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(profile=_system_profiles(), tag=st.integers(min_value=0, max_value=10_000))
def test_persistence_round_trip_preserves_all_fields(profile, tag, tmp_path):
  # A per-example subdirectory keeps generated inputs isolated even though the
  # tmp_path fixture is shared across the hypothesis examples.
  svc = _service(str(tmp_path / f"run_{tag}"))

  svc._write_file(profile)
  loaded = svc._read_file()

  assert loaded is not None
  assert isinstance(loaded, SystemProfile)
  # Every Static and OS field is preserved exactly through write -> read.
  for group_name in ("static", "os"):
    original_group = getattr(profile, group_name)
    loaded_group = getattr(loaded, group_name)
    for f in fields(original_group):
      assert getattr(loaded_group, f.name) == getattr(original_group, f.name)
  # Structural equivalence of the whole profile (frozen dataclass equality).
  assert loaded == profile


# ---------------------------------------------------------------------------
# Example tests — read/degradation branches and write guarantees
# ---------------------------------------------------------------------------

def _sample_profile() -> SystemProfile:
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


class TestReadFileBranches:
  def test_missing_file_returns_none(self, tmp_path):
    svc = _service(str(tmp_path))
    assert svc._read_file() is None

  def test_invalid_json_returns_none(self, tmp_path):
    svc = _service(str(tmp_path))
    with open(svc._system_info_file, "w", encoding="utf-8") as handle:
      handle.write("{not valid json ~~~")
    assert svc._read_file() is None

  def test_non_object_json_returns_none(self, tmp_path):
    svc = _service(str(tmp_path))
    with open(svc._system_info_file, "w", encoding="utf-8") as handle:
      json.dump(["not", "an", "object"], handle)
    assert svc._read_file() is None

  def test_unknown_keys_ignored(self, tmp_path):
    svc = _service(str(tmp_path))
    document = {
      "version": 1,
      "static": {"cpu_model": "Test CPU", "surprise": "ignored"},
      "os": {"os_name": "TestOS", "extra": 123},
      "top_level_unknown": True,
    }
    with open(svc._system_info_file, "w", encoding="utf-8") as handle:
      json.dump(document, handle)

    profile = svc._read_file()
    assert profile is not None
    assert profile.static.cpu_model == "Test CPU"
    assert profile.os.os_name == "TestOS"

  def test_absent_fields_default_to_unknown(self, tmp_path):
    svc = _service(str(tmp_path))
    document = {"version": 1, "static": {"cpu_model": "Test CPU"}, "os": {}}
    with open(svc._system_info_file, "w", encoding="utf-8") as handle:
      json.dump(document, handle)

    profile = svc._read_file()
    assert profile is not None
    # Every field not present in the file defaults to UNKNOWN, so the profile
    # is always total.
    assert profile.static.cpu_model == "Test CPU"
    assert profile.static.physical_cores == UNKNOWN
    assert profile.static.total_vram_bytes == UNKNOWN
    assert profile.os.os_name == UNKNOWN
    assert profile.os.python_version == UNKNOWN

  def test_missing_groups_yield_total_unknown_profile(self, tmp_path):
    svc = _service(str(tmp_path))
    with open(svc._system_info_file, "w", encoding="utf-8") as handle:
      json.dump({"version": 1}, handle)

    profile = svc._read_file()
    assert profile is not None
    for group in (profile.static, profile.os):
      for f in fields(group):
        assert getattr(group, f.name) == UNKNOWN


class TestWriteFile:
  def test_written_document_has_version_and_all_fields(self, tmp_path):
    svc = _service(str(tmp_path))
    svc._write_file(_sample_profile())

    with open(svc._system_info_file, "r", encoding="utf-8") as handle:
      document = json.load(handle)

    assert document["version"] == 1
    assert set(document["static"]) == {f.name for f in fields(StaticMetrics)}
    assert set(document["os"]) == {f.name for f in fields(OSMetrics)}

  def test_write_creates_missing_data_dir(self, tmp_path):
    nested = os.path.join(str(tmp_path), "does", "not", "exist")
    svc = _service(nested)
    svc._write_file(_sample_profile())
    assert os.path.isfile(svc._system_info_file)

  def test_unknown_fields_are_serialized(self, tmp_path):
    svc = _service(str(tmp_path))
    profile = SystemProfile(static=StaticMetrics(), os=OSMetrics())
    svc._write_file(profile)

    with open(svc._system_info_file, "r", encoding="utf-8") as handle:
      document = json.load(handle)

    assert document["static"]["cpu_model"] == UNKNOWN
    assert document["os"]["os_name"] == UNKNOWN

  def test_write_failure_is_swallowed(self, tmp_path):
    # A data_dir path that is actually a file makes makedirs/open fail; the
    # write must log and return without raising (Requirement 3.3).
    clash = os.path.join(str(tmp_path), "clash")
    with open(clash, "w", encoding="utf-8") as handle:
      handle.write("i am a file, not a directory")
    svc = _service(clash)
    # Should not raise.
    svc._write_file(_sample_profile())
