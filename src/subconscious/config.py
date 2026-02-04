import os
import sys
import yaml
import logging
import pathlib
from typing import Optional
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

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

@dataclass
class Config:
  dev: bool = False
  config_path: Optional[str] = None
  data_dir: pathlib.Path = field(default_factory=get_default_data_dir)

  def exists(self) -> bool:
    """ Checks if the config file exists at the specified or default path. """
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    return path.exists()

  def load(self):
    """ Loads config from the YAML file. """
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    if path.exists():
      with open(path, 'r') as f:
        data = yaml.safe_load(f)
        if data:
          self.data_dir = pathlib.Path(data.get('data_dir', self.data_dir))
          # Other config fields can be loaded here

  def save(self):
    """ Saves config to the YAML file. """
    path = pathlib.Path(self.config_path) if self.config_path else self.data_dir / "config.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
      yaml.safe_dump({
        'data_dir': str(self.data_dir)
      }, f)

def log_config(config: Config, mode: str):
  print(LOGO)
  logger.info(f"Mode: {mode}")
  logger.info(f"Development: {config.dev}")
  logger.info(f"Config Path: {config.config_path or 'Default'}")
  logger.info("----------------------------------")
