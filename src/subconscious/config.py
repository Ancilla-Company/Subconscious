import logging
from typing import Optional
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass
class Config:
  dev: bool = False
  config_path: Optional[str] = None

def log_config(config: Config, mode: str):
  logger.info("--- Subconscious Configuration ---")
  logger.info(f"Mode: {mode}")
  logger.info(f"Development: {config.dev}")
  logger.info(f"Config Path: {config.config_path or 'Default'}")
  logger.info("----------------------------------")
