# PyInstaller spec: builds one folder containing two executables that share
# the same runtime:
#   subconscious.exe       console build, for terminals / CLI use
#   subconscious-tray.exe  windowed build, for shortcuts (no console flash)
#
# Run from the repository root:
#   python -m PyInstaller packaging/engine/subconscious.spec --noconfirm \
#       --distpath build/packaging/pyinstaller --workpath build/packaging/pyinstaller-work
from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_submodules, copy_metadata

root = Path(SPECPATH).resolve().parents[1]
engine_src = root / "engine" / "src"
icon = str(engine_src / "subconscious_engine" / "app_icon.ico")

datas, binaries, hiddenimports = [], [], []
for package in (
    "subconscious_engine",  # graphs/*.json and app_icon.ico
    "pydantic_ai",
    "pydantic_graph",
    "sentence_transformers",
    "keyring",
    "pystray",
):
    package_datas, package_binaries, package_hidden = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hidden
# Hive (WebRTC) native modules: aiortc and its dependencies ship compiled
# extensions (av, pylibsrtp, cffi backends) that PyInstaller cannot discover.
for package in ("aiortc", "aioice", "av", "pylibsrtp", "OpenSSL", "cffi", "cryptography", "google_crc32c", "pyee", "dns"):
    try:
        package_datas, package_binaries, package_hidden = collect_all(package)
    except Exception:  # optional on platforms where a wheel is absent
        continue
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hidden
hiddenimports += ["_cffi_backend", "subconscious_engine.hive.service"]
for package in ("genai_prices", "logfire"):
    package_datas, package_binaries, package_hidden = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hidden
# Many libraries read their own version via importlib.metadata at import time.
for distribution in ("pydantic-ai", "sentence-transformers", "keyring", "uvicorn"):
    datas += copy_metadata(distribution, recursive=True)
hiddenimports += collect_submodules("uvicorn")
hiddenimports += ["keyring.backends.Windows", "pystray._win32", "tkinter"]

analysis = Analysis(
    [str(root / "packaging" / "engine" / "entry.py")],
    pathex=[str(engine_src)],
    datas=datas,
    binaries=binaries,
    hiddenimports=hiddenimports,
    excludes=["pytest", "selenium"],
)
pyz = PYZ(analysis.pure)

console_exe = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="subconscious",
    console=True,
    icon=icon,
)
tray_exe = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="subconscious-tray",
    console=False,
    icon=icon,
)
COLLECT(
    console_exe,
    tray_exe,
    analysis.binaries,
    analysis.datas,
    name="engine",
)
