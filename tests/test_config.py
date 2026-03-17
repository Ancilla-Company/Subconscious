import pytest
from subconscious.config import Config


def test_config_defaults():
  config = Config()
  assert config.dev is False
  assert "-dev" not in str(config.data_dir)

def test_config_custom():
  config = Config(dev=True)
  assert config.dev is True
  assert "-dev" in str(config.data_dir)
