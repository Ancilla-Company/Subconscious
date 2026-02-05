import sys
import cmd
import logging
import pathlib
import asyncio

from .engine import start_engine
from .config import Config, log_config, LOGO

# Platform specific non-blocking input check
if sys.platform == 'win32':
  try:
    import msvcrt
  except ImportError:
    msvcrt = None # type: ignore
  select = None # type: ignore
  termios = None # type: ignore
  tty = None # type: ignore
else:
  msvcrt = None # type: ignore
  try:
    import select
    import termios
    import tty
  except ImportError:
    select = None # type: ignore
    termios = None # type: ignore
    tty = None # type: ignore


logger = logging.getLogger(__name__)


class SubconsciousCLI(cmd.Cmd):
  """Command processor for Subconscious."""
  intro = "Welcome to Subconscious! Type 'help' or '?' to list commands.\nPress any key to interrupt streaming output."
  prompt = "\n[You] "

  def __init__(self, config: Config):
    super().__init__()
    self.config = config
    self.should_exit = False
    self.last_chat_input = None

  def do_quit(self, arg):
    """Quit the application."""
    self.should_exit = True
    return True

  def do_exit(self, arg):
    """Exit the application."""
    self.should_exit = True
    return True

  def default(self, line):
    """Handle default behavior (chat input)."""
    if line == 'EOF':
      self.should_exit = True
      return True
    # Capture the input line for async processing
    self.last_chat_input = line

  def emptyline(self):
    """Do nothing on empty input."""
    pass

  async def stream_output(self, text: str):
    """Stream output character by character, allowing interruption."""
    print("\n[Subconscious]", end=" ", flush=True)

    fd = sys.stdin.fileno()
    old_settings = None
    if termios and tty:
      try:
        old_settings = termios.tcgetattr(fd)
        tty.setcbreak(fd)
      except Exception:
        pass # Not a TTY

    try:
      for char in text:
        interrupted = False
        
        if msvcrt:
          if msvcrt.kbhit():
            interrupted = True
            while msvcrt.kbhit():
              msvcrt.getch()
        elif old_settings and select:
          dr, _, _ = select.select([sys.stdin], [], [], 0)
          if dr:
            interrupted = True
            # Flush
            sys.stdin.read(1)
            while True:
              dr, _, _ = select.select([sys.stdin], [], [], 0)
              if not dr: break
              sys.stdin.read(1)

        if interrupted:
          if old_settings and termios:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
            old_settings = None
          print("\n[Output interrupted]")
          return

        print(char, end="", flush=True)
        await asyncio.sleep(0.01)

    finally:
      if old_settings and termios:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        
    print() # Newline at end


async def setup_flow(config: Config):
  """Prompt the user for the data directory."""
  print(LOGO)
  print("Welcome to Subconscious!")
  print("\nSetup Required:")
  print(f"Please confirm or edit the data directory location.")
  print(f"Default: {config.data_dir}")
  print("\nPress Enter to use default or type a new path:")

  loop = asyncio.get_running_loop()
  # Use standard input in executor to avoid blocking async loop
  user_input = await loop.run_in_executor(None, input)
  
  path_str = user_input.strip()
  path = pathlib.Path(path_str) if path_str else config.data_dir
  config.data_dir = path
  config.save()
  
  print(f"\nConfig saved to: {path / 'config.yaml'}")


async def main_loop(config: Config):
  cli = SubconsciousCLI(config)
  
  # Print CLI intro
  print(cli.intro)
  print("-" * 40)
  
  loop = asyncio.get_running_loop()
  
  while not cli.should_exit:
    # Display prompt
    sys.stdout.write(cli.prompt)
    sys.stdout.flush()
    
    try:
      # Read input in a separate thread so the event loop isn't blocked
      line = await loop.run_in_executor(None, sys.stdin.readline)
    except asyncio.CancelledError:
      break

    if not line: # EOF
      break
      
    line = line.strip()
    
    # Process command using cmd logic
    cli.onecmd(line)
    
    # If user entered chat text, process it asynchronously
    if cli.last_chat_input:
      message = cli.last_chat_input
      cli.last_chat_input = None # Reset
      
      # Simulate initial processing/thinking time
      # In a real app, this would be the agent thinking
      print(f"[Processing '{message}'...]")
      await asyncio.sleep(0.5)
      
      # Simulate a streaming response
      start_msg = f"Simulated analysis of: '{message}'."
      dummy_content = " This is a simulated response stream. " * 3
      interruption_hint = " (Press any key to interrupt me while I'm typing!)"
      full_response = start_msg + dummy_content + interruption_hint
      
      await cli.stream_output(full_response)

  print("\nGoodbye!")


async def start_tui(config: Config):
  """ CLI startup logic """
  if not config.exists():
    await setup_flow(config)
  else:
    config.load(tui=True)
    
  # Log intro
  log_config(config)
    
  # Start the engine in the background
  engine_task = asyncio.create_task(start_engine(config))

  try:
    await main_loop(config)
  finally:
    engine_task.cancel()
    try:
      await engine_task
    except asyncio.CancelledError:
      pass
