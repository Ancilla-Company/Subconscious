import logging
import subprocess
import sys

from subconscious_engine import desktop_launcher as dl


def _no_dev(monkeypatch):
    monkeypatch.setattr(dl, "_DEV_RELEASE_RELATIVE", dl.Path("does/not/exist.exe"))


def test_env_var_wins(tmp_path, monkeypatch):
    exe = tmp_path / "custom.exe"
    exe.write_text("x")
    monkeypatch.setenv(dl.DESKTOP_EXE_ENVIRONMENT_VARIABLE, str(exe))
    found, _ = dl.find_desktop_executable()
    assert found == exe


def test_frozen_layout(tmp_path, monkeypatch):
    _no_dev(monkeypatch)
    monkeypatch.delenv(dl.DESKTOP_EXE_ENVIRONMENT_VARIABLE, raising=False)
    (tmp_path / "engine").mkdir()
    (tmp_path / "gui").mkdir()
    engine = tmp_path / "engine" / "subconscious-desktop.exe"
    engine.write_text("x")
    gui = tmp_path / "gui" / "gui.exe"
    gui.write_text("x")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(engine))
    found, _ = dl.find_desktop_executable()
    assert found == gui.resolve()


def test_dev_fallback(tmp_path, monkeypatch):
    monkeypatch.delenv(dl.DESKTOP_EXE_ENVIRONMENT_VARIABLE, raising=False)
    monkeypatch.delattr(sys, "frozen", raising=False)
    dev = dl.Path(dl.__file__).resolve().parents[3] / dl._DEV_RELEASE_RELATIVE
    assert dev in dl.candidate_desktop_paths()


def test_not_found_logs_error(monkeypatch, caplog):
    _no_dev(monkeypatch)
    monkeypatch.delenv(dl.DESKTOP_EXE_ENVIRONMENT_VARIABLE, raising=False)
    monkeypatch.delattr(sys, "frozen", raising=False)
    with caplog.at_level(logging.ERROR):
        dl.launch_desktop_app("http://x", "secret")
    assert any("not found" in r.getMessage() for r in caplog.records)


def test_popen_flags(tmp_path, monkeypatch):
    exe = tmp_path / "gui.exe"
    exe.write_text("x")
    monkeypatch.setenv(dl.DESKTOP_EXE_ENVIRONMENT_VARIABLE, str(exe))
    calls = []
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: calls.append((a, k)))
    dl.launch_desktop_app("http://x", "secret-token")
    args, kwargs = calls[0]
    assert args[0] == [str(exe)]
    assert "secret-token" not in " ".join(args[0])
    assert kwargs["cwd"] == str(tmp_path)
    assert kwargs["stdout"] == subprocess.DEVNULL
    assert kwargs["close_fds"] is True
    if sys.platform == "win32":
        flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        assert kwargs["creationflags"] == flags


def test_popen_failure_logged(tmp_path, monkeypatch, caplog):
    exe = tmp_path / "gui.exe"
    exe.write_text("x")
    monkeypatch.setenv(dl.DESKTOP_EXE_ENVIRONMENT_VARIABLE, str(exe))

    def boom(*a, **k):
        raise OSError("nope")

    monkeypatch.setattr(subprocess, "Popen", boom)
    with caplog.at_level(logging.ERROR):
        dl.launch_desktop_app("a", "b")
    assert any(r.exc_info for r in caplog.records)
