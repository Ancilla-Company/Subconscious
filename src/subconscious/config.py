import os
import sys
import uuid
import yaml
import time
import logging
import pathlib
import keyring
from typing import Optional
from dataclasses import dataclass, field


# Logging setup
logger = logging.getLogger("subconscious")


LOGO = """
                 ⢀⣠⣴⣶⣤⣀           ⢀⣀⣀⡀            
                ⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣶⣾⣿⣿⣿⣿⣷⡀          
                ⣸⣿⣿⣿⣿⣿⣿⡿⠉⠉⠉⠉⠉⠉⠉⠉⢻⣿⣿⣿⣿⣿⣿⡇          
              ⢀⣼⣿⡿⢿⣿⣿⣿⣿⣷⡀      ⢀⣼⣿⣿⣿⣿⣿⡿⠁          
             ⢠⣿⣿⠟     ⠹⣿⣿⣦⣀⣀⡀⢀⣴⣿⣿⠟⠉⠙⠋⠉            
          ⢀⣴⣾⣿⣿⣿⣄      ⠈⣻⣿⣿⣿⣿⣿⣿⠟⠁                 
          ⣾⣿⣿⣿⣿⣿⣿⣶⣶⣶⣶⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿                   
          ⢻⣿⣿⣿⣿⣿⣿⠛⠛⠛⠋⠉⠉⠉⠻⣿⣿⣿⣿⣿⡟                   
           ⠙⠻⢿⣿⣿⡁        ⠈⢻⣿⣿⠁                    
              ⠻⣿⣿⣷⣤⣀      ⣸⣿⡇                     
                ⠙⠻⢿⣿⣿⣷⣶⣤⣤⣾⣿⣿⣿⣶⡀                   
                    ⠉⠛⠻⢿⣿⣿⣿⣿⣿⣿⣿                   
                       ⠈⢿⣿⣿⣿⣿⣿⣿⣿⣷⣦⣄               
                        ⢰⣿⣿⠟⠛⠉ ⠉⠛⢿⣿⣿⣦⡀            
                     ⢀⣀⣤⣿⣿⠇       ⠈⠻⣿⣷⡄           
                    ⣴⣿⣿⣿⣿⣿⣆         ⢹⣿⣷           
                   ⢸⣿⣿⣿⣿⣿⣿⣿⣄⡀       ⢸⣿⣿           
                  ⢀⣴⣿⣿⣿⣿⣿⣿⠿⣿⣿⣿⣶⣤⣀⡀⢀⣤⣼⣿⣿⡀          
                ⢀⣴⣿⣿⠟⠉⣿⣿⡏   ⠉⠙⠻⠿⣿⣿⣿⣿⣿⣿⣿⣿⡄         
           ⣀⣤⣤⣀⣴⣿⣿⠟⠁  ⣿⣿⡇        ⢻⣿⣿⣿⣿⣿⣿⡇         
         ⢠⣾⣿⣿⣿⣿⣿⡟⠁    ⢸⣿⡇       ⢀⣬⣿⣿⣿⣿⡿⠏          
         ⢸⣿⣿⣿⣿⣿⣿⣧⣀⣀ ⢠⣶⣿⣿⣿⣷⣄ ⣀⣠⣤⣶⣿⣿⠟⠁              
         ⠈⢿⣿⣿⣿⣿⠿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠿⠟⠋                 
           ⠈⠉⠉⠁    ⠉⢻⣿⣿⣿⣿⣿⡿⠉                      
                     ⠙⠛⠛⠛⠋                   ⠀
"""


def get_default_data_dir() -> pathlib.Path:
  """ Returns the default data directory based on the OS. """
  if sys.platform == "win32":
    return pathlib.Path(os.environ.get("APPDATA", "~")).expanduser() / "Subconscious"
  elif sys.platform == "darwin":
    return pathlib.Path.home() / "Library" / "Application Support" / "Subconscious"
  else:
    # Linux/Unix default to XDG_CONFIG_HOME or ~/.config
    xdg_config = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config:
      return pathlib.Path(xdg_config) / "subconscious"
    return pathlib.Path.home() / ".config" / "subconscious"


class KeyManager:
  """Manage API keys using the system keyring service."""
  SERVICE_NAME = "subconscious-engine"

  @staticmethod
  def set_key(provider: str, key: str):
    """Securely store an API key."""
    try:
      keyring.set_password(KeyManager.SERVICE_NAME, provider.upper(), key)
      return True
    except Exception as e:
      logger.error(f"Failed to set key for {provider}: {e}")
      return False

  @staticmethod
  def get_key(provider: str) -> Optional[str]:
    """Retrieve an API key."""
    try:
      return keyring.get_password(KeyManager.SERVICE_NAME, provider.upper())
    except Exception as e:
      logger.error(f"Failed to get key for {provider}: {e}")
      return None


@dataclass
class Config:
  dev: bool = False
  tui: bool = False
  gui: bool = False
  node_id: Optional[str] = None
  secrets: Optional[dict] = None
  data_dir: pathlib.Path = field(default_factory=get_default_data_dir)

  def __post_init__(self):
    if self.dev:
      self.data_dir = get_default_data_dir()
      self.data_dir = self.data_dir.with_name(f"{self.data_dir.name}-dev")

  def load(self):
    """ Loads config from the YAML file. """
    path = self.data_dir / "config.yaml"
    if path.exists():
      with open(path, 'r') as f:
        data = yaml.safe_load(f)
        if data:
          self.node_id = data.get('node_id', self.node_id)
          self.secrets = data.get('secrets', self.secrets)
    else:
      # Create a config file
      logger.info(f"No config file found at {path}. Creating one...")
      self.node_id = str(uuid.uuid4())
      self.secrets = {}
      self.save()
      logger.info(f"Config file created at {path}.")

  def save(self):
    """ Saves config to the YAML file. """
    path = self.data_dir / "config.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
      yaml.safe_dump({
        'node_id': str(self.node_id),
        'secrets': self.secrets,
      }, f)

  @property
  def db_path(self) -> str:
    """Returns the path to the SQLite database."""
    return f"sqlite+aiosqlite:///{self.data_dir / 'subconscious.db'}"


def log_config(config: Config):
  """ Logs the current configuration settings. """
  print("-" * 40)
  if config.tui:
    print("Mode: Engine + CLI")
  if config.gui:
    print("Mode: Engine + GUI")
  else:
    print("Mode: Engine")
  print(f"Live: {not config.dev}")
  print(f"Node ID: {config.node_id}")
  print(f"Data Directory: {config.data_dir}")
  print("-" * 40)
