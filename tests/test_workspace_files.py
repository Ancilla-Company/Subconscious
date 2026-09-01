import asyncio
import json
import os

import pytest

from subconscious_engine.api.schemas import CreateWorkspaceRequest
from subconscious_engine.services.workspace_files import WorkspaceFileError, WorkspaceFileService
from subconscious_engine.services.workspaces import WorkspaceService
from subconscious_engine.storage.database import Database


def run(coro):
    return asyncio.run(coro)


def assert_error(status, action, text=None):
    with pytest.raises(WorkspaceFileError) as caught:
        action()
    assert caught.value.status_code == status
    if text:
        assert text in str(caught.value)


async def configured_service(db_path, root):
    database = Database(db_path)
    await database.initialize()
    session = database.session_factory()
    workspace = await WorkspaceService(session).create(
        CreateWorkspaceRequest(name="files", directories=json.dumps([str(root)]))
    )
    return database, session, WorkspaceFileService(session), workspace.uuid


def test_async_file_crud_and_directory_first_listing_use_real_sqlite(tmp_path):
    async def scenario():
        root = tmp_path / "root"
        root.mkdir()
        database, session, service, workspace_id = await configured_service(
            tmp_path / "files.db", root
        )
        try:
            directory = await service.create_directory(workspace_id, 0, "src")
            created = await service.create(workspace_id, 0, "z.txt", "hello")
            await service.create(workspace_id, 0, "a.py", "print('a')")
            assert directory.is_directory and created.content == "hello"
            assert [item.name for item in await service.list(workspace_id, 0, None)] == [
                "src", "a.py", "z.txt"
            ]
            assert (await service.read(workspace_id, 0, "z.txt")).content == "hello"
            assert (await service.write(workspace_id, 0, "z.txt", "short")).content == "short"
            assert (root / "z.txt").read_text(encoding="utf-8") == "short"
        finally:
            await session.close()
            await database.close()
    run(scenario())


@pytest.mark.parametrize("path", ["", "/absolute.txt", "C:/drive.txt", "../escape.txt",
                                  "a/../b.txt", "a//b.txt", "./a.txt"])
def test_relative_path_parser_rejects_empty_absolute_and_traversal_paths(path):
    assert_error(400, lambda: WorkspaceFileService._parts(path, allow_root=False),
                 "workspace-relative")


def test_sync_security_and_content_validation(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    root.mkdir()
    (root / "bom.txt").write_bytes(b"\xef\xbb\xbfhello")
    (root / "binary.txt").write_bytes(b"\xff")
    (root / "folder").mkdir()

    assert service._read_sync(root, "bom.txt").content == "hello"
    assert_error(400, lambda: service._read_sync(root, "binary.txt"), "UTF-8")
    assert_error(400, lambda: service._read_sync(root, "folder"), "file")
    assert_error(400, lambda: service._create_sync(root, "bad.exe", "", b""), "supported")
    assert_error(404, lambda: service._create_sync(root, "missing/a.txt", "", b""), "does not exist")
    assert_error(409, lambda: service._create_sync(root, "bom.txt", "", b""), "already exists")
    assert_error(400, lambda: service._encode(None), "required")
    assert_error(400, lambda: service._encode("x" * (service.MAX_BYTES + 1)), "1 MB")


def test_read_rejects_oversized_file_before_decoding(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    root.mkdir()
    (root / "large.txt").write_bytes(b"x" * (service.MAX_BYTES + 1))
    assert_error(400, lambda: service._read_sync(root, "large.txt"), "1 MB")


def test_symlinks_are_hidden_and_cannot_be_followed(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    outside = tmp_path / "outside"
    root.mkdir()
    outside.mkdir()
    (outside / "secret.txt").write_text("secret", encoding="utf-8")
    link = root / "link"
    try:
        link.symlink_to(outside, target_is_directory=True)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symlink creation unavailable: {error}")

    assert service._list_sync(root, None) == []
    assert_error(403, lambda: service._read_sync(root, "link/secret.txt"), "reparse point")
    assert_error(409, lambda: service._create_directory_sync(root, "link"), "already exists")


def test_root_reports_missing_workspace_bad_index_and_invalid_configuration(tmp_path):
    async def scenario():
        root = tmp_path / "root"
        root.mkdir()
        database, session, service, workspace_id = await configured_service(
            tmp_path / "roots.db", root
        )
        try:
            with pytest.raises(WorkspaceFileError) as missing:
                await service.root("missing", 0)
            assert missing.value.status_code == 404
            with pytest.raises(WorkspaceFileError) as bad_index:
                await service.root(workspace_id, 1)
            assert bad_index.value.status_code == 400

            row = await WorkspaceService(session).get(workspace_id)
            row.directories = "not-json"
            await session.commit()
            with pytest.raises(WorkspaceFileError) as malformed:
                await service.root(workspace_id, 0)
            assert malformed.value.status_code == 400

            row.directories = json.dumps(["relative/path"])
            await session.commit()
            with pytest.raises(WorkspaceFileError) as relative:
                await service.root(workspace_id, 0)
            assert relative.value.status_code == 400
        finally:
            await session.close()
            await database.close()
    run(scenario())
