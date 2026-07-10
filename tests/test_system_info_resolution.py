"""
Property-based and example tests for ``SystemInformationService`` profile
resolution (spec: system-information-context, task 5.1).

Covered correctness properties (see design.md):
  - Property 5 (Missing or corrupt file recovery): for any initial file state
    that is either absent or contains arbitrary unreadable/unparseable content,
    ``ensure_profile()`` performs collection exactly once, caches the resulting
    total profile, and leaves a valid, re-readable ``System_Info_File`` on disk.
  - Property 6 (In-memory reuse idempotence): for any number of successive
    ``get_profile()`` calls on a single service instance after the profile has
    been resolved, the profile is loaded or collected at most once and the
    ``System_Info_File`` is not read again — every call returns an identical
    profile.

Example tests additionally cover the load path (present readable file reused
without collecting) and the never-raise contract of ``ensure_profile`` /
``get_profile`` under an unexpected internal error.
"""

import uuid
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


def _install_collect_counter(svc, monkeypatch, profile=None):
  """Replace ``_collect`` with a counting stub and return the counter list.

  The counter is a single-element list so the closure can mutate it. The stub
  returns ``profile`` (a fully-populated sample profile by default) so the
  cached profile is total.
  """
  counter = [0]
  result = profile if profile is not None else _sample_profile()

  def _counting_collect():
    counter[0] += 1
    return result

  monkeypatch.setattr(svc, "_collect", _counting_collect)
  return counter


def _install_read_counter(svc, monkeypatch):
  """Wrap the real ``_read_file`` with a counter; return the counter list."""
  counter = [0]
  original = svc._read_file

  def _counting_read():
    counter[0] += 1
    return original()

  monkeypatch.setattr(svc, "_read_file", _counting_read)
  return counter


def _assert_total(profile: SystemProfile) -> None:
  assert isinstance(profile, SystemProfile)
  for group in (profile.static, profile.os):
    for f in fields(group):
      value = getattr(group, f.name)
      assert isinstance(value, str)
      assert value != ""


# ---------------------------------------------------------------------------
# Property 5: Missing or corrupt file recovery
# ---------------------------------------------------------------------------

# Initial file state is either absent (None) or arbitrary non-JSON/invalid
# bytes written to the System_Info_File before ensure_profile runs.
_initial_state = st.one_of(
  st.none(),
  st.binary(max_size=200),
  st.text(max_size=200).map(lambda s: s.encode("utf-8", errors="ignore")),
)


# Feature: system-information-context, Property 5: For any initial file state
# that is either absent or contains arbitrary unreadable/unparseable content,
# ensure_profile() performs collection exactly once, caches the resulting total
# profile, and leaves a valid, re-readable System_Info_File on disk.
# Validates: Requirements 4.2, 4.3
@settings(
  max_examples=100,
  deadline=None,
  suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(initial=_initial_state)
def test_missing_or_corrupt_file_recovery(initial, tmp_path, monkeypatch):
  # A unique per-example subdirectory keeps generated inputs isolated: the
  # tmp_path fixture is shared across hypothesis examples, so reusing it would
  # let one example's written file leak into the next.
  svc = _service(str(tmp_path / f"run_{uuid.uuid4().hex}"))

  # Seed the initial on-disk state. When ``initial`` is None the file is absent;
  # otherwise it holds arbitrary bytes that must not parse as a valid profile
  # document (guaranteed unparseable by prefixing a non-JSON marker only when
  # needed is unnecessary — arbitrary bytes rarely form the exact schema, and
  # even valid JSON objects missing the schema still round-trip; to make the
  # corrupt-branch deterministic we ensure the bytes are not a valid object).
  if initial is not None:
    import os as _os

    _os.makedirs(svc._data_dir, exist_ok=True)
    # Prefix with a byte that guarantees JSON decoding fails, forcing the
    # unreadable/unparseable branch regardless of the generated content.
    with open(svc._system_info_file, "wb") as handle:
      handle.write(b"\x00not-json" + initial)

  counter = _install_collect_counter(svc, monkeypatch)

  svc.ensure_profile()

  # Collection ran exactly once.
  assert counter[0] == 1
  # A total profile is cached.
  assert svc._profile is not None
  _assert_total(svc._profile)
  # A valid, re-readable file was left on disk.
  reread = svc._read_file()
  assert reread is not None
  assert reread == svc._profile


# ---------------------------------------------------------------------------
# Property 6: In-memory reuse idempotence
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 6: For any number of successive
# get_profile() calls on a single service instance after the profile has been
# resolved, the profile is loaded or collected at most once and the
# System_Info_File is not read again — every call returns an identical profile.
# Validates: Requirements 4.4
@settings(
  max_examples=100,
  deadline=None,
  suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(
  calls=st.integers(min_value=1, max_value=20),
  file_present=st.booleans(),
)
def test_in_memory_reuse_idempotence(calls, file_present, tmp_path, monkeypatch):
  svc = _service(str(tmp_path / f"run_{uuid.uuid4().hex}"))

  # Optionally pre-seed a valid file so the load path is also exercised.
  if file_present:
    svc._write_file(_sample_profile())

  collect_counter = _install_collect_counter(svc, monkeypatch)
  read_counter = _install_read_counter(svc, monkeypatch)

  results = [svc.get_profile() for _ in range(calls)]

  # The file is read at most once (only during the first resolution) and
  # collection runs at most once.
  assert read_counter[0] <= 1
  assert collect_counter[0] <= 1
  # Exactly one of load-or-collect happened.
  assert read_counter[0] + collect_counter[0] >= 1
  # Every call returns an identical profile (same object identity — the cache
  # is reused, not rebuilt).
  first = results[0]
  for profile in results:
    assert profile is first
    assert profile == first


# ---------------------------------------------------------------------------
# Example tests — load path and never-raise contract
# ---------------------------------------------------------------------------

class TestEnsureProfileLoadPath:
  def test_present_readable_file_is_loaded_without_collecting(
    self, tmp_path, monkeypatch
  ):
    svc = _service(str(tmp_path))
    svc._write_file(_sample_profile())

    def _fail_collect():
      raise AssertionError("collection must not run when a valid file exists")

    monkeypatch.setattr(svc, "_collect", _fail_collect)

    svc.ensure_profile()

    assert svc._profile == _sample_profile()

  def test_cached_profile_short_circuits_without_file_access(
    self, tmp_path, monkeypatch
  ):
    svc = _service(str(tmp_path))
    svc._profile = _sample_profile()

    def _fail_read():
      raise AssertionError("file must not be read when a profile is cached")

    monkeypatch.setattr(svc, "_read_file", _fail_read)

    # Must return immediately without touching the file.
    svc.ensure_profile()
    assert svc._profile == _sample_profile()


class TestNeverRaises:
  def test_ensure_profile_caches_unknown_on_unexpected_error(
    self, tmp_path, monkeypatch
  ):
    svc = _service(str(tmp_path))

    def _boom():
      raise RuntimeError("unexpected internal failure")

    # An unexpected error anywhere in resolution must be swallowed.
    monkeypatch.setattr(svc, "_read_file", _boom)

    svc.ensure_profile()  # must not raise

    assert svc._profile == SystemProfile(
      static=StaticMetrics(), os=OSMetrics()
    )
    # Confirm the fallback is a total all-UNKNOWN profile.
    for group in (svc._profile.static, svc._profile.os):
      for f in fields(group):
        assert getattr(group, f.name) == UNKNOWN

  def test_get_profile_never_raises_and_returns_total_profile(
    self, tmp_path, monkeypatch
  ):
    svc = _service(str(tmp_path))

    def _boom():
      raise RuntimeError("unexpected internal failure")

    monkeypatch.setattr(svc, "_read_file", _boom)

    profile = svc.get_profile()  # must not raise
    _assert_total(profile)
