from typing import Optional
from dataclasses import dataclass


@dataclass
class Config:
  dev: bool = False
  config_path: Optional[str] = None

def print_config(config: Config, mode: str):
  print(f"--- Subconscious Configuration ---")
  print(f"Mode: {mode}")
  print(f"Development: {config.dev}")
  print(f"Config Path: {config.config_path or 'Default'}")
  print(f"----------------------------------")
