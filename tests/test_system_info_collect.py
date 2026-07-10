"""
Property-based and example tests for ``SystemInformationService._collect``
(spec: system-information-context, task 3.1).

Covered correctness properties (see design.md):
  - Property 1 (Total coverage): for any configuration of underlying probes
    (each succeeding, failing, or returning nothing), the collected
    ``SystemProfile`` contains an entry for every defined Static and OS metric
    field, and no field is ``None`` or missing.
  - Property 2 (Graceful degradation): for any subset of probes that raise or
    return empty (including the optional ``psutil`` library being absent),
    collection records exactly those metrics as ``UNKNOWN``, still collects
    every other probe, and never propagates an exception.
  - Property 9 (PII exclusion): for any host environment — including one seeded
    with sentinel username/hostname values — the returned ``SystemProfile``
    contains none of the excluded PII categories.

All probes are monkeypatched/injected so the tests never depend on real host
hardware.
"""

from dataclasses import fields
from unittest import mock

import os

from hypothesis import given, settings, strategies as st

from subconscious.system_info import (
  UNKNOWN,
  OSMetrics,
  StaticMetrics,
  SystemInformationService,
  SystemProfile,
)


def _service() -> SystemInformationService:
  """A service instance; collection behaviour is independent of ``data_dir``."""
  return SystemInformationService(data_dir="")


# Map each scalar probe method to (metric group, field name, fake "ok" value).
STATIC_SCALAR_PROBES = {
  "_probe_cpu_model": ("cpu_model", "AMD Ryzen 9 5900X"),
  "_probe_physical_cores": ("physical_cores", 12),
  "_probe_logical_cores": ("logical_cores", 24),
  "_probe_total_ram_bytes": ("total_ram_bytes", 34359738368),
  "_probe_cpu_architecture": ("cpu_architecture", "x86_64"),
}
OS_SCALAR_PROBES = {
  "_probe_os_name": ("os_name", "Windows 10"),
  "_probe_os_version": ("os_version", "10.0.19045"),
  "_probe_machine_architecture": ("machine_architecture", "AMD64"),
  "_probe_python_version": ("python_version", "3.12.4"),
}
GPU_OK = {"model": "NVIDIA GeForce RTX 3080", "vram_bytes": 10737418240, "accelerator": "CUDA"}

# All toggleable probe keys (the GPU probe drives three fields at once).
ALL_PROBE_KEYS = list(STATIC_SCALAR_PROBES) + list(OS_SCALAR_PROBES) + ["gpu"]


def _raise() -> object:
  raise RuntimeError("probe forced to fail")


def _install_probes(svc: SystemInformationService, fail_set: set) -> None:
  """Replace every probe with a fake: failing probes raise, others return a
  known value. Injecting fakes keeps the test independent of real hardware."""
  for key, (_field, value) in {**STATIC_SCALAR_PROBES, **OS_SCALAR_PROBES}.items():
    if key in fail_set:
      setattr(svc, key, _raise)
    else:
      setattr(svc, key, (lambda v=value: v))
  if "gpu" in fail_set:
    svc._probe_gpu = _raise
  else:
    svc._probe_gpu = lambda: dict(GPU_OK)


def _assert_total_coverage(profile: SystemProfile) -> None:
  """Every Static and OS field is present as a non-empty string (Property 1)."""
  assert isinstance(profile, SystemProfile)
  for group in (profile.static, profile.os):
    for f in fields(group):
      value = getattr(group, f.name)
      assert value is not None, f"{f.name} is None"
      assert isinstance(value, str), f"{f.name} is not a str: {value!r}"
      assert value != "", f"{f.name} is empty"


# ---------------------------------------------------------------------------
# Property 1: Total coverage
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 1: For any configuration of
# underlying probes (each succeeding, failing, or returning nothing), the
# SystemProfile returned contains an entry for every defined Static and OS
# metric field, and no field is None or missing — each field is either a
# concrete value or exactly "unknown".
# Validates: Requirements 1.1, 1.2, 1.4, 2.1, 5.4, 5.5
@settings(max_examples=100, deadline=None)
@given(fail_set=st.sets(st.sampled_from(ALL_PROBE_KEYS)))
def test_total_coverage_over_any_probe_configuration(fail_set):
  svc = _service()
  _install_probes(svc, fail_set)

  profile = svc._collect()

  # Never raises and always yields a total profile with every field set.
  _assert_total_coverage(profile)
  # Field count is exactly the defined static + os metrics (nothing missing).
  assert len(fields(profile.static)) == 8
  assert len(fields(profile.os)) == 4


# ---------------------------------------------------------------------------
# Property 2: Graceful degradation
# ---------------------------------------------------------------------------

# Feature: system-information-context, Property 2: For any arbitrary subset of
# metric probes that raise an error or return an empty/undeterminable value,
# collection records exactly those metrics as "unknown", still collects every
# probe not in that subset, and never propagates an exception.
# Validates: Requirements 1.5, 2.2, 5.2, 5.3
@settings(max_examples=100, deadline=None)
@given(fail_set=st.sets(st.sampled_from(ALL_PROBE_KEYS)))
def test_graceful_degradation_failed_subset_becomes_unknown(fail_set):
  svc = _service()
  _install_probes(svc, fail_set)

  profile = svc._collect()

  # Scalar static/os metrics: failed -> UNKNOWN, succeeded -> known value.
  for key, (field, value) in {**STATIC_SCALAR_PROBES, **OS_SCALAR_PROBES}.items():
    group = profile.static if key in STATIC_SCALAR_PROBES else profile.os
    got = getattr(group, field)
    if key in fail_set:
      assert got == UNKNOWN
    else:
      assert got == str(value)

  # GPU probe drives three fields together.
  if "gpu" in fail_set:
    assert profile.static.gpu_model == UNKNOWN
    assert profile.static.total_vram_bytes == UNKNOWN
    assert profile.static.accelerator == UNKNOWN
  else:
    assert profile.static.gpu_model == "NVIDIA GeForce RTX 3080"
    assert profile.static.total_vram_bytes == "10737418240"
    assert profile.static.accelerator == "CUDA"


class _FakeVirtualMemory:
  total = 34359738368


class _FakePsutil:
  """Minimal stand-in for the optional ``psutil`` module."""

  @staticmethod
  def cpu_count(logical=True):
    return 16 if logical else 8

  @staticmethod
  def virtual_memory():
    return _FakeVirtualMemory()


# Feature: system-information-context, Property 2: including the case where the
# optional inspection library (psutil) is entirely unavailable, collection
# falls back to the standard library, marks only genuinely unobtainable metrics
# as "unknown", and never raises.
# Validates: Requirements 1.5, 2.2, 5.2, 5.3
@settings(max_examples=100, deadline=None)
@given(psutil_present=st.booleans())
def test_graceful_degradation_optional_library_absent(psutil_present):
  svc = _service()
  # Drive optional-library availability.
  svc._get_psutil = (lambda: _FakePsutil) if psutil_present else (lambda: None)
  # Neutralize any real shell-outs so the test never touches host hardware.
  svc._run_command = lambda *args, **kwargs: ""
  # Deterministic stdlib RAM fallback for the psutil-absent path.
  svc._probe_total_ram_bytes_stdlib = lambda: 17179869184

  profile = svc._collect()

  _assert_total_coverage(profile)
  if psutil_present:
    assert profile.static.physical_cores == "8"
    assert profile.static.logical_cores == "16"
    assert profile.static.total_ram_bytes == "34359738368"
  else:
    # Physical cores have no portable stdlib source -> UNKNOWN when psutil gone.
    assert profile.static.physical_cores == UNKNOWN
    # Logical cores and RAM still degrade gracefully via stdlib fallbacks.
    assert profile.static.logical_cores != UNKNOWN
    assert profile.static.total_ram_bytes == "17179869184"


# ---------------------------------------------------------------------------
# Property 9: PII exclusion
# ---------------------------------------------------------------------------

_PII_SENTINEL = "PII_SENTINEL_ZZZ_1234567890"


# Feature: system-information-context, Property 9: For any host environment —
# including one seeded with sentinel username and hostname values — the returned
# SystemProfile contains none of the excluded PII categories (username,
# hostname, device serial numbers, MAC addresses, IP addresses).
# Validates: Requirements 7.1
@settings(max_examples=100, deadline=None)
@given(
  pii_vars=st.lists(
    st.sampled_from(
      ["USERNAME", "USER", "LOGNAME", "HOSTNAME", "COMPUTERNAME", "HOST"]
    ),
    unique=True,
  )
)
def test_pii_excluded_from_collected_profile(pii_vars):
  svc = _service()
  # Keep collection host-independent and fast (no real shell-outs / psutil).
  svc._run_command = lambda *args, **kwargs: ""
  svc._get_psutil = lambda: None
  svc._probe_total_ram_bytes_stdlib = lambda: 17179869184

  # Seed the environment with sentinel PII values (reset after the test).
  seeded = {name: _PII_SENTINEL for name in pii_vars}
  with mock.patch.dict(os.environ, seeded):
    profile = svc._collect()

  _assert_total_coverage(profile)
  for group in (profile.static, profile.os):
    for f in fields(group):
      assert _PII_SENTINEL not in getattr(group, f.name)


# ---------------------------------------------------------------------------
# Example tests — collection guarantees
# ---------------------------------------------------------------------------

class TestCollectExamples:
  def test_all_probes_failing_yields_all_unknown(self):
    svc = _service()
    _install_probes(svc, set(ALL_PROBE_KEYS))

    profile = svc._collect()

    _assert_total_coverage(profile)
    for group in (profile.static, profile.os):
      for f in fields(group):
        assert getattr(group, f.name) == UNKNOWN

  def test_all_probes_succeeding_yields_all_values(self):
    svc = _service()
    _install_probes(svc, set())

    profile = svc._collect()

    assert profile.static.cpu_model == "AMD Ryzen 9 5900X"
    assert profile.static.physical_cores == "12"
    assert profile.static.total_ram_bytes == "34359738368"
    assert profile.static.gpu_model == "NVIDIA GeForce RTX 3080"
    assert profile.static.total_vram_bytes == "10737418240"
    assert profile.static.accelerator == "CUDA"
    assert profile.os.os_name == "Windows 10"
    assert profile.os.python_version == "3.12.4"

  def test_collect_never_raises_with_real_probes(self):
    # Exercise the real platform probes on the running host; the contract is
    # simply that a total profile comes back without raising.
    svc = _service()
    profile = svc._collect()
    _assert_total_coverage(profile)

  def test_gpu_probe_failure_isolated_from_other_metrics(self):
    svc = _service()
    _install_probes(svc, {"gpu"})

    profile = svc._collect()

    assert profile.static.gpu_model == UNKNOWN
    assert profile.static.total_vram_bytes == UNKNOWN
    assert profile.static.accelerator == UNKNOWN
    # A GPU failure must not affect the other static metrics.
    assert profile.static.cpu_model == "AMD Ryzen 9 5900X"
    assert profile.static.physical_cores == "12"

  def test_budget_exhausted_leaves_remaining_metrics_unknown(self):
    # Force the budget to be already exceeded so no probe runs.
    import subconscious.system_info as sysinfo

    svc = _service()
    _install_probes(svc, set())
    original = sysinfo.COLLECTION_BUDGET_SECONDS
    sysinfo.COLLECTION_BUDGET_SECONDS = -1.0
    try:
      profile = svc._collect()
    finally:
      sysinfo.COLLECTION_BUDGET_SECONDS = original

    _assert_total_coverage(profile)
    for group in (profile.static, profile.os):
      for f in fields(group):
        assert getattr(group, f.name) == UNKNOWN
