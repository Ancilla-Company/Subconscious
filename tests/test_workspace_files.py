import asyncio
from io import BytesIO
import json
import os
import zipfile

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
    png = b"\x89PNG\r\n\x1a\npreview"
    pdf = b"%PDF-1.7\n%%EOF"
    docx_buffer = BytesIO()
    with zipfile.ZipFile(docx_buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", "<w:document/>")
    docx = docx_buffer.getvalue()
    (root / "preview.png").write_bytes(png)
    (root / "preview.pdf").write_bytes(pdf)
    (root / "preview.docx").write_bytes(docx)
    (root / "invalid.png").write_bytes(b"not-a-png")
    (root / "invalid.pdf").write_bytes(b"not-a-pdf")
    (root / "invalid.docx").write_bytes(b"not-a-docx")

    assert service._read_sync(root, "bom.txt").content == "hello"
    assert_error(400, lambda: service._read_sync(root, "binary.txt"), "UTF-8")
    assert_error(400, lambda: service._read_sync(root, "folder"), "file")
    # No extension allowlist: an unusual or absent extension is still plain
    # text as long as it decodes as UTF-8. ".kiroignore" has no name before
    # its dot at all, and a made-up extension is just as readable.
    assert service._create_sync(root, "bad.madeupext", "hi", b"hi").content == "hi"
    (root / ".kiroignore").write_text("node_modules/", encoding="utf-8")
    assert service._read_sync(root, ".kiroignore").content == "node_modules/"
    assert_error(404, lambda: service._create_sync(root, "missing/a.txt", "", b""), "does not exist")
    assert_error(409, lambda: service._create_sync(root, "bom.txt", "", b""), "already exists")
    assert_error(400, lambda: service._encode(None), "required")
    assert_error(400, lambda: service._encode("x" * (service.MAX_BYTES + 1)), "1 MB")

    image_preview = service._preview_sync(root, "preview.png")
    assert (image_preview.content, image_preview.media_type, image_preview.kind) == (
        png, "image/png", "image"
    )
    pdf_preview = service._preview_sync(root, "preview.pdf")
    assert (pdf_preview.content, pdf_preview.media_type, pdf_preview.kind) == (
        pdf, "application/pdf", "pdf"
    )
    docx_preview = service._preview_sync(root, "preview.docx")
    assert docx_preview.content == docx
    assert docx_preview.kind == "docx"
    assert docx_preview.media_type.endswith("wordprocessingml.document")
    assert_error(400, lambda: service._preview_sync(root, "invalid.png"), "signature")
    assert_error(400, lambda: service._preview_sync(root, "invalid.pdf"), "valid PDF")
    assert_error(400, lambda: service._preview_sync(root, "invalid.docx"), "DOCX")


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


def test_move_can_rename_in_place_and_still_moves_between_folders(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    (root / "sub").mkdir(parents=True)
    (root / "a.txt").write_text("x")

    moved = service._move_sync(root, "a.txt", "sub")
    assert moved.relative_path == "sub/a.txt"

    renamed = service._move_sync(root, "sub/a.txt", "sub", "b.txt")
    assert renamed.relative_path == "sub/b.txt"
    assert (root / "sub" / "b.txt").read_text() == "x"
    assert not (root / "sub" / "a.txt").exists()

    # A change of letter case alone is a rename, not a clash with itself.
    assert service._move_sync(root, "sub/b.txt", "sub", "B.txt").name == "B.txt"


def test_rename_rejects_bad_names_and_clashes(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    root.mkdir()
    (root / "a.txt").write_text("a")
    (root / "b.txt").write_text("b")

    for bad in ("", "..", "x/y", "x\\y", "a:b", "trailing."):
        assert_error(400, lambda bad=bad: service._move_sync(root, "a.txt", "", bad))
    assert_error(400, lambda: service._move_sync(root, "a.txt", "", "a.txt"), "same")
    assert_error(409, lambda: service._move_sync(root, "a.txt", "", "b.txt"))
    # A plain move into the folder it is already in is still refused.
    assert_error(400, lambda: service._move_sync(root, "a.txt", ""), "already")


def test_delete_removes_files_and_whole_directories(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    (root / "dir" / "nested").mkdir(parents=True)
    (root / "dir" / "nested" / "deep.txt").write_text("deep")
    (root / "dir" / "top.md").write_text("top")
    (root / "keep.txt").write_text("keep")
    (root / "locked.txt").write_text("locked")
    os.chmod(root / "locked.txt", 0o444)

    service._delete_sync(root, "keep.txt")
    assert not (root / "keep.txt").exists()

    # A read-only file is still deleted (Windows refuses unless the flag is cleared).
    service._delete_sync(root, "locked.txt")
    assert not (root / "locked.txt").exists()

    os.chmod(root / "dir" / "top.md", 0o444)
    service._delete_sync(root, "dir")
    assert not (root / "dir").exists()
    assert root.exists() and list(root.iterdir()) == []


def test_delete_refuses_root_traversal_missing_and_engine_folder(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    root.mkdir()
    (root / ".subconscious").mkdir()
    (root / ".subconscious" / "sidecar.db").write_bytes(b"x")
    outside = tmp_path / "outside.txt"
    outside.write_text("outside")

    assert_error(400, lambda: service._delete_sync(root, ""), "required")
    assert_error(400, lambda: service._delete_sync(root, "../outside.txt"), "traversal")
    assert_error(404, lambda: service._delete_sync(root, "missing.txt"), "does not exist")
    assert_error(403, lambda: service._delete_sync(root, ".subconscious"), "managed")
    assert_error(403, lambda: service._delete_sync(root, ".subconscious/sidecar.db"), "managed")
    assert outside.exists()
    assert (root / ".subconscious" / "sidecar.db").exists()


def test_delete_never_follows_links_out_of_the_root(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    outside = tmp_path / "outside"
    (root / "dir").mkdir(parents=True)
    outside.mkdir()
    (outside / "secret.txt").write_text("secret", encoding="utf-8")
    try:
        (root / "link").symlink_to(outside, target_is_directory=True)
        (root / "dir" / "inner").symlink_to(outside, target_is_directory=True)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symlink creation unavailable: {error}")

    # The link itself is a reparse point and is refused.
    assert_error(403, lambda: service._delete_sync(root, "link"), "reparse point")
    # A link inside a deleted directory is removed, not followed.
    service._delete_sync(root, "dir")
    assert not (root / "dir").exists()
    assert (outside / "secret.txt").read_text(encoding="utf-8") == "secret"


def test_copy_copies_files_and_directories_without_changing_the_source(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    (root / "source" / "nested").mkdir(parents=True)
    (root / "destination").mkdir()
    (root / "note.md").write_text("note", encoding="utf-8")
    (root / "source" / "nested" / "deep.txt").write_text("deep", encoding="utf-8")

    copied_file = service._copy_sync(root, "note.md", root, "destination")
    assert (copied_file.name, copied_file.relative_path, copied_file.is_directory) == (
        "note.md", "destination/note.md", False
    )
    assert (root / "note.md").read_text(encoding="utf-8") == "note"
    assert (root / "destination" / "note.md").read_text(encoding="utf-8") == "note"

    copied_directory = service._copy_sync(root, "source", root, "destination")
    assert (copied_directory.name, copied_directory.relative_path, copied_directory.is_directory) == (
        "source", "destination/source", True
    )
    assert (root / "source" / "nested" / "deep.txt").read_text(encoding="utf-8") == "deep"
    assert (root / "destination" / "source" / "nested" / "deep.txt").read_text(encoding="utf-8") == "deep"


def test_copy_names_a_conflicting_dotfile_without_an_extension_split(tmp_path):
    """A leading-dot name with nothing before the dot, like ".kiroignore", has
    no extension to protect: the whole name is the stem, so a conflict is
    named ".kiroignore Copy", not "Copy.kiroignore" (which would turn a
    dotfile into a visible file with a ".kiroignore" extension)."""
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    root.mkdir()
    (root / ".kiroignore").write_text("node_modules/", encoding="utf-8")

    copied = service._copy_sync(root, ".kiroignore", root, "")
    assert copied.relative_path == ".kiroignore Copy"
    assert (root / ".kiroignore Copy").read_text(encoding="utf-8") == "node_modules/"

    copied_again = service._copy_sync(root, ".kiroignore", root, "")
    assert copied_again.relative_path == ".kiroignore Copy 2"


def test_copy_refuses_collisions_managed_paths_and_self_descendants(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    (root / "source" / "child").mkdir(parents=True)
    (root / "destination").mkdir()
    (root / "source" / "a.txt").write_text("a")
    (root / "destination" / "source").mkdir()
    (root / ".subconscious").mkdir()

    # A name clash at the destination gets a " Copy" suffix instead of failing.
    conflicted = service._copy_sync(root, "source", root, "destination")
    assert conflicted.relative_path == "destination/source Copy"
    assert (root / "destination" / "source Copy" / "a.txt").read_text() == "a"

    assert_error(400, lambda: service._copy_sync(root, "source", root, "source/child"), "itself")
    assert_error(403, lambda: service._copy_sync(root, ".subconscious", root, "destination"), "managed")
    assert_error(403, lambda: service._copy_sync(root, "source", root, ".subconscious"), "managed")
    assert_error(404, lambda: service._copy_sync(root, "missing", root, "destination"), "does not exist")
    assert_error(400, lambda: service._copy_sync(root, "", root, "destination"), "required")


def test_copy_rejects_reparse_entries_inside_a_directory(tmp_path):
    service = WorkspaceFileService(None)
    root = tmp_path / "root"
    outside = tmp_path / "outside"
    (root / "source").mkdir(parents=True)
    (root / "destination").mkdir()
    outside.mkdir()
    (outside / "secret.txt").write_text("secret", encoding="utf-8")
    try:
        (root / "source" / "link").symlink_to(outside, target_is_directory=True)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symlink creation unavailable: {error}")

    assert_error(403, lambda: service._copy_sync(root, "source", root, "destination"), "reparse point")
    assert not (root / "destination" / "source").exists()
    assert (outside / "secret.txt").read_text(encoding="utf-8") == "secret"


def test_copy_works_between_two_roots_of_one_workspace(tmp_path):
    service = WorkspaceFileService(None)
    first = tmp_path / "first"
    second = tmp_path / "second"
    (first / "notes").mkdir(parents=True)
    second.mkdir()
    (first / "notes" / "a.md").write_text("alpha", encoding="utf-8")

    copied = service._copy_sync(first, "notes/a.md", second, "")
    assert copied.relative_path == "a.md"
    assert (second / "a.md").read_text(encoding="utf-8") == "alpha"
    assert (first / "notes" / "a.md").read_text(encoding="utf-8") == "alpha"

    copied_folder = service._copy_sync(first, "notes", second, "")
    assert copied_folder.relative_path == "notes"
    assert (second / "notes" / "a.md").read_text(encoding="utf-8") == "alpha"

    # A repeated copy of the same file gets "a Copy.md", then "a Copy 2.md".
    again = service._copy_sync(first, "notes/a.md", second, "")
    assert again.relative_path == "a Copy.md"
    again2 = service._copy_sync(first, "notes/a.md", second, "")
    assert again2.relative_path == "a Copy 2.md"
