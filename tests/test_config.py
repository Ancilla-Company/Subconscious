import pytest
from subconscious.config import Config


def test_config_defaults():
  config = Config()
  assert config.dev is False
  assert config.config_path is None

def test_config_custom():
  config = Config(dev=True, config_path="test.yaml")
  assert config.dev is True
  assert config.config_path == "test.yaml"
