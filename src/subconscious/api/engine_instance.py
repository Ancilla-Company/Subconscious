from typing import Optional

from ..config import Config
from ..engine import Engine


# Global engine instance
_engine_instance: Optional[Engine] = None


async def get_engine_instance(config: Config) -> Engine:
  """Get or create the global engine instance."""
  global _engine_instance

  if _engine_instance is None:
    _engine_instance = Engine()
    await _engine_instance.start_engine(config)

  return _engine_instance