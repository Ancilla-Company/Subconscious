import json
from unittest.mock import patch

import pytest

from subconscious_engine.runtime import RuntimeInfo, RuntimeInfoWriter


def info(port=8123):
    return RuntimeInfo(host="127.0.0.1", port=port, token="secret", pid=42,
                       version="1.2.3", node_id="node-a")


def test_path_write_and_atomic_overwrite(tmp_path):
    assert RuntimeInfoWriter.path_for(tmp_path) == tmp_path / "runtime.json"
    RuntimeInfoWriter.write(tmp_path, info())
    RuntimeInfoWriter.write(tmp_path, info(9000))
    payload = json.loads((tmp_path / "runtime.json").read_text(encoding="utf-8"))
    assert payload == info(9000).model_dump(mode="json")
    assert not list(tmp_path.glob(".runtime.json.*.tmp"))


def test_write_creates_parent_and_replaces_from_temporary_file(tmp_path):
    directory = tmp_path / "nested"
    with patch("subconscious_engine.runtime.os.replace", wraps=__import__("os").replace) as replace:
        RuntimeInfoWriter.write(directory, info())
    source, destination = replace.call_args.args
    assert source.parent == directory
    assert source.name.startswith(".runtime.json.") and source.suffix == ".tmp"
    assert destination == directory / "runtime.json"


def test_failed_replace_cleans_temporary_file(tmp_path):
    with patch("subconscious_engine.runtime.os.replace", side_effect=OSError("locked")):
        with pytest.raises(OSError, match="locked"):
            RuntimeInfoWriter.write(tmp_path, info())
    assert not (tmp_path / "runtime.json").exists()
    assert not list(tmp_path.glob(".runtime.json.*.tmp"))


def test_delete_is_idempotent_and_suppresses_os_errors(tmp_path):
    RuntimeInfoWriter.delete(tmp_path)
    RuntimeInfoWriter.write(tmp_path, info())
    RuntimeInfoWriter.delete(tmp_path)
    assert not (tmp_path / "runtime.json").exists()
    with patch("pathlib.Path.unlink", side_effect=PermissionError("busy")):
        RuntimeInfoWriter.delete(tmp_path)


def test_runtime_model_allows_optional_node_id():
    value = RuntimeInfo(host="localhost", port=1, token="t", pid=2, version="v")
    assert value.node_id is None
