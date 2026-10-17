import pytest


@pytest.fixture(autouse=True)
def _no_real_engine_log_from_cli_tests(request, monkeypatch):
    """CLI tests call main() in-process; keep them from writing the user's real engine.log."""
    if request.module.__name__.endswith("test_logging_setup"):
        return
    monkeypatch.setattr("subconscious_engine.__main__.configure_engine_logging", lambda *a, **k: None)
