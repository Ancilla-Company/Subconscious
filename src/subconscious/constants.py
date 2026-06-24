import os
from importlib.metadata import version, PackageNotFoundError


try:
  VERSION = "v" + version("subconscious-chat")
except PackageNotFoundError:
  VERSION = "v0.0.0"


# Base URL of the Subconscious identity/sync server. Overridable via the
# SUBCONSCIOUS_SERVER_URL environment variable for local development against a
# server running on localhost.
SERVER_URL = os.environ.get("SUBCONSCIOUS_SERVER_URL", "https://api.subconscious.chat").rstrip("/")
