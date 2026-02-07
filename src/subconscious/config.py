import os
import sys
import uuid
import yaml
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
  config_path: Optional[str] = None
  data_dir: pathlib.Path = field(default_factory=get_default_data_dir)
  subconscious_id: str = field(default_factory=lambda: str(uuid.uuid4()))
  model_provider: Optional[str] = None
  model_name: Optional[str] = None
  current_workspace: Optional[str] = None
  default_workspace: str = str(uuid.uuid4())

  def exists(self) -> bool:
    """ Checks if the config file exists at the specified or default path. """
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    return path.exists()

  def validate(self):
    """ Verifies that the config file contains all required fields. Saves the current state if values are missing. """
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    
    if not path.exists():
      self.save()
      return

    try:
      with open(path, 'r') as f:
        data = yaml.safe_load(f) or {}
      
      expected_keys = ['data_dir', 'subconscious_id', 'default_workspace']
      if any(k not in data for k in expected_keys):
        logger.info(f"Config file at {path} is incomplete. Synchronizing with current dataclass state...")
        self.save()
    except Exception as e:
      logger.error(f"Failed to validate config file: {e}")
      self.save() # Attempt to fix by overwriting with current state

  def load(self, tui: bool = False):
    """ Loads config from the YAML file. """
    self.tui = tui
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    if path.exists():
      with open(path, 'r') as f:
        data = yaml.safe_load(f)
        if data:
          self.data_dir = pathlib.Path(data.get('data_dir', self.data_dir))
          self.subconscious_id = data.get('subconscious_id', self.subconscious_id)
          self.model_provider = data.get('model_provider', self.model_provider)
          self.model_name = data.get('model_name', self.model_name)
          self.current_workspace = data.get('current_workspace', self.current_workspace)
          self.default_workspace = data.get('default_workspace', self.default_workspace)

  def save(self):
    """ Saves config to the YAML file. """
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
      yaml.safe_dump({
        'data_dir': str(self.data_dir),
        'subconscious_id': self.subconscious_id,
        'model_provider': self.model_provider,
        'model_name': self.model_name,
        'current_workspace': self.current_workspace,
        'default_workspace': self.default_workspace
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
  else:
    print("Mode: Engine Only")
  print(f"Live: {not config.dev}")
  print(f"Subconscious ID: {config.subconscious_id}")
  print(f"Data Directory: {config.data_dir}")
  print("-" * 40)
