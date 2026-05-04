from importlib.metadata import version, PackageNotFoundError

try:
  VERSION = "v" + version("subconscious-chat")
except PackageNotFoundError:
  VERSION = "v0.0.0"
