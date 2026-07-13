""" Local engine API package.

    Starts a non-blocking uvicorn server bound to loopback
    Publishes a ``runtime.json`` discovery file
    so local clients can find the port and obtain the session token.
"""
from __future__ import annotations

import asyncio
import logging
from typing import TYPE_CHECKING
import uvicorn

from ..config import Config
from .app import create_app, build_uvicorn_log_config
from ..constants import VERSION
from .runtime import (
  generate_token, find_free_port, write_runtime_file, remove_runtime_file,
)

if TYPE_CHECKING:
  from ..engine import Engine


# Logging setup
logger = logging.getLogger("subconscious")


class APIService:
  """ Controllable, non-blocking handle for the local engine API """
  def __init__(self, engine: Engine, config: Config, *, preferred_port: int = 8771) -> None:
    self.engine = engine
    self.config = config
    self.preferred_port = preferred_port

    self.port: int | None = None
    self.token: str | None = None
    self._task: asyncio.Task | None = None
    self._server: uvicorn.Server | None = None

  @property
  def is_running(self) -> bool:
    """ True while the background server task is alive """
    return self._task is not None and not self._task.done()

  @property
  def url(self) -> str | None:
    """ The loopback URL the API is bound to, or None when not started """
    if self.port is None:
      return None
    return f"http://127.0.0.1:{self.port}"

  async def start(self) -> "APIService":
    """ Start the API server in a background task and return this service.

        Returns immediately once uvicorn reports it has started (so the ``port``
        is reliable). Re-raises any startup error such as a port-bind failure.
        A no-op if already running.
    """
    if self.is_running:
      logger.warning("APIService.start() called while already running; ignoring.")
      return self

    self.token = generate_token()
    app = create_app(self.engine, self.token)
    self.port = find_free_port(self.preferred_port)

    write_runtime_file(
      port=self.port,
      token=self.token,
      version=VERSION,
      data_dir=self.config.data_dir,
      node_id=getattr(self.config, "node_id", None),
    )

    uvicorn_config = uvicorn.Config(
      app, host="127.0.0.1", port=self.port, log_level="info", loop="asyncio",
      log_config=build_uvicorn_log_config(getattr(self.config, "dev", False)),
    )
    self._server = uvicorn.Server(uvicorn_config)
    # uvicorn installs process-wide signal handlers by default, which only works
    # on the main thread and would clobber the host application's handlers.
    # Disable them: lifecycle is driven explicitly via stop().
    self._server.install_signal_handlers = lambda: None

    self._task = asyncio.create_task(self._serve(), name="subconscious-api")

    # Wait until the server is actually accepting connections (or it failed).
    while not self._server.started and not self._task.done():
      await asyncio.sleep(0.05)

    if self._task.done():
      # Startup failed (e.g. port bind error) — clean up and surface the error.
      remove_runtime_file(self.config.data_dir)
      exc = self._task.exception()
      self._server = None
      self._task = None
      if exc:
        raise exc

    logger.info("Subconscious engine API listening on %s", self.url)
    return self

  async def _serve(self) -> None:
    """ Run the uvicorn server, removing the discovery file on exit """
    try:
      await self._server.serve()
    finally:
      remove_runtime_file(self.config.data_dir)

  async def stop(self, *, timeout: float = 10.0) -> None:
    """ Gracefully stop the server, cancelling the task if it overruns *timeout*. """
    if not self.is_running:
      return

    assert self._server is not None and self._task is not None
    self._server.should_exit = True

    try:
      await asyncio.wait_for(asyncio.shield(self._task), timeout=timeout)
    except asyncio.TimeoutError:
      logger.warning("API server did not shut down within %ss; cancelling.", timeout)
      self._task.cancel()

      try:
        await self._task
      except asyncio.CancelledError:
        pass

    finally:
      self._server = None
      self._task = None
      self.port = None
      self.token = None
      logger.info("Subconscious engine API stopped.")

  async def restart(self) -> "APIService":
    """ Stop the server (if running) and start it again """
    await self.stop()
    return await self.start()
