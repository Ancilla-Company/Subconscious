"""Stop a process together with everything it started.

An agent such as ``kiro-cli`` starts helper processes of its own, and some of them detach
(``kiro-cli-chat`` outlives its parent and keeps the session locked). Terminating only the
process we launched would leave those running, so the descendants are listed first, while the
parent links still exist, and then stopped as well.

Standard library only: ``ps`` on Linux and macOS, the ToolHelp snapshot API on Windows.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys
from collections.abc import Iterable

_LOG = logging.getLogger(__name__)


def descendants(pid: int) -> list[int]:
    """All live descendants of ``pid``, deepest first (the order to stop them in)."""
    try:
        parents = _windows_parents() if sys.platform == "win32" else _posix_parents()
    except Exception:
        _LOG.warning("services.process_tree.descendants: could not list processes", exc_info=True)
        return []
    children: dict[int, list[int]] = {}
    for child, parent in parents.items():
        children.setdefault(parent, []).append(child)
    ordered: list[int] = []
    stack = [pid]
    seen = {pid}
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in seen:
                seen.add(child)
                ordered.append(child)
                stack.append(child)
    return list(reversed(ordered))


def _posix_parents() -> dict[int, int]:
    import subprocess
    output = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True,
                            timeout=5, check=False).stdout
    parents: dict[int, int] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            parents[int(parts[0])] = int(parts[1])
    return parents


def _windows_parents() -> dict[int, int]:
    import ctypes
    from ctypes import wintypes

    class ProcessEntry(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
            ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
    kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    snapshot = kernel32.CreateToolhelp32Snapshot(0x2, 0)  # TH32CS_SNAPPROCESS
    if snapshot in (None, wintypes.HANDLE(-1).value):
        raise OSError("CreateToolhelp32Snapshot failed")
    parents: dict[int, int] = {}
    try:
        entry = ProcessEntry()
        entry.dwSize = ctypes.sizeof(ProcessEntry)
        more = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            parents[int(entry.th32ProcessID)] = int(entry.th32ParentProcessID)
            more = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return parents


def is_alive(pid: int) -> bool:
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        try:
            code = wintypes.DWORD()
            return bool(kernel32.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        _LOG.debug("services.process_tree.is_alive: pid %s is gone", pid, exc_info=True)
        return False
    except PermissionError:
        _LOG.debug("services.process_tree.is_alive: pid %s exists but is not ours", pid, exc_info=True)
        return True
    return True


def _stop(pids: Iterable[int], *, force: bool) -> None:
    for pid in pids:
        try:
            if sys.platform == "win32":
                os.kill(pid, signal.SIGTERM)  # TerminateProcess; Windows has no softer signal
            else:
                os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            _LOG.debug("services.process_tree._stop: pid %s already gone or not ours", pid, exc_info=True)


async def stop_tree(process: asyncio.subprocess.Process, known: Iterable[int] = (), *,
                    grace: float = 3.0) -> None:
    """Stop ``process`` and all its descendants, then reap ``process``.

    ``known`` is a snapshot of descendants taken earlier (before the parent exited, while the
    links were intact); descendants found now are added to it. Everything gets a polite
    stop, a short grace period, and then a forced kill.
    """
    pids = list(dict.fromkeys([*known, *(descendants(process.pid) if process.returncode is None else [])]))
    if process.returncode is None:
        try:
            process.terminate()
        except ProcessLookupError:
            _LOG.debug("services.process_tree.stop_tree: process already exited", exc_info=True)
    _stop(pids, force=False)
    deadline = asyncio.get_running_loop().time() + grace
    while asyncio.get_running_loop().time() < deadline:
        if process.returncode is not None and not any(is_alive(pid) for pid in pids):
            break
        await asyncio.sleep(0.05)
    survivors = [pid for pid in pids if is_alive(pid)]
    if process.returncode is None:
        try:
            process.kill()
        except ProcessLookupError:
            _LOG.debug("services.process_tree.stop_tree: process exited before kill", exc_info=True)
    if survivors:
        _LOG.warning("services.process_tree.stop_tree: forcing %d stubborn process(es)", len(survivors))
        _stop(survivors, force=True)
    try:
        await asyncio.wait_for(process.wait(), 5)
    except asyncio.TimeoutError:
        _LOG.warning("services.process_tree.stop_tree: process did not exit after kill", exc_info=True)
