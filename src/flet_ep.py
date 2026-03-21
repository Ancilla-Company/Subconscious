""" Default flet build entrypoint """
import sys
from subconscious.cli import main


if __name__ == "__main__":
  if "gui" not in sys.argv:
    sys.argv.insert(1, "gui")
  main()
