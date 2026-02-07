import sys
import cmd
import logging
import pathlib
import asyncio

from .engine import Engine  
from .config import Config, log_config, LOGO, KeyManager

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


# Logging setup
logger = logging.getLogger("subconscious")


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

  def do_add_key(self, arg):
    """Add an API key. Usage: add_key <provider> <nickname> <key>"""
    args = arg.split()
    if len(args) != 3:
      print("Usage: add_key <provider> <nickname> <key>")
      return
    
    provider, nickname, key = args
    identifier = f"{provider}:{nickname}"
    if KeyManager.set_key(identifier, key):
      print(f"Key saved as '{identifier}'. You can use this by setting model_provider to '{provider}:{identifier}'.")
    else:
      print("Failed to save key.")

  def do_set_model(self, arg):
    """Set the current model. Usage: set_model <provider> <model_name>"""
    args = arg.split()
    if len(args) != 2:
      print("Usage: set_model <provider> <model_name>")
      return
    
    self.config.model_provider, self.config.model_name = args
    self.config.save()
    print(f"Model updated to {self.config.model_provider} using {self.config.model_name}. Please restart the application (or types 'reload') to apply changes.")

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

  async def stream_output(self, stream_iter):
    """Stream output from an async iterator, allowing interruption."""
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
      async for chunk in stream_iter:
        # Pydantic-ai stream chunks might be objects or strings 
        # based on how it's used. For simple text, it's usually the delta.
        text_chunk = str(chunk) 
        
        for char in text_chunk:
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

    except Exception as e:
      print(f"\n[Error during streaming: {e}]")
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

async def main_loop(config: Config, engine: Engine):
  cli = SubconsciousCLI(config)
  
  # Print CLI intro
  print(cli.intro)
  print("-" * 40)
  
  if not config.model_provider or not config.model_name:
    print("\n[System] No AI model configured. Chat functionality will be limited.")
    print("[System] Use 'set_model <provider> <model_name>' and 'add_key <provider> <nickname> <key>' to get started.")
    print("[System] Example: set_model openai gpt-4o")

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
      
      # Process via Engine's agent
      try:
        stream = engine.run_agent_stream(message)
        await cli.stream_output(stream)
      except Exception as e:
        print(f"Error: {e}")

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
  engine = Engine()
  await engine.start_engine(config)
  await main_loop(config, engine)
