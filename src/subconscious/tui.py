import asyncio
import logging
import pathlib
from typing import Optional
from textual.app import App, ComposeResult
from .config import Config, log_config, LOGO
from textual.widgets import Header, Footer, RichLog, Input, Static

logger = logging.getLogger(__name__)


class SelectableRichLog(RichLog):
  """A RichLog that allows text selection and focus."""
  ALLOW_SELECT = True
  can_focus = True

class SubconsciousApp(App):
  """A Textual app for Subconscious."""

  TITLE = "Subconscious"
  SUB_TITLE = "Distributed Agentic Engine"

  CSS = """
  SelectableRichLog {
    height: 1fr;
    border: double $accent;
    background: $surface;
    color: $text;
    margin: 0 2;
    padding: 1 2;
    scrollbar-gutter: stable;
  }

  SelectableRichLog:focus {
    border: double $primary;
  }

  Input {
    margin: 1 2;
    border: tall $accent;
  }
  """

  def __init__(self, config: Config, **kwargs):
    super().__init__(**kwargs)
    self.config = config
    self.is_setup_mode = False

  def compose(self) -> ComposeResult:
    yield Header()
    log = SelectableRichLog(id="main_log", wrap=True, highlight=True, markup=True)
    log.can_focus = True
    yield log
    yield Input(placeholder="Type a message...", id="main_input")
    yield Footer()

  def on_mount(self) -> None:
    if not self.config.exists():
      self.start_setup_flow()
    else:
      self.config.load()
      self.initialize_ui(show_logo=True)

  def start_setup_flow(self) -> None:
    """ Prompt the user for the data directory in the chat box. """
    self.is_setup_mode = True
    log = self.query_one("#main_log", SelectableRichLog)
    log.write(LOGO)
    log.write("Welcome to [bold magenta]Subconscious[/bold magenta]!")
    log.write("\n[bold yellow]Setup Required:[/bold yellow]")
    log.write(f"Please confirm or edit the data directory location.")
    log.write(f"Default: [cyan]{self.config.data_dir}[/cyan]")
    log.write("\nPress [bold]Enter[/bold] to use default or type a new path:")
    
    input_widget = self.query_one("#main_input", Input)
    input_widget.placeholder = "Enter data directory path..."
    input_widget.value = str(self.config.data_dir)
    input_widget.focus()

  def initialize_ui(self, show_logo: bool = True) -> None:
    self.is_setup_mode = False
    log = self.query_one("#main_log", SelectableRichLog)
    
    if show_logo:
      log.write(LOGO)
    else:
      log.write("-" * 40)

    log.write(f" [bold green]Mode:[/bold green] Engine + TUI")
    log.write(f" [bold green]Development:[/bold green] {self.config.dev}")
    log.write(f" [bold green]Data Directory:[/bold green] [cyan]{self.config.data_dir}[/cyan]")
    log.write("\nWelcome to [bold magenta]Subconscious[/bold magenta]!")
    log.write("Type a message below to interact with the engine.")
    log.write("-" * 40)
    
    input_widget = self.query_one("#main_input", Input)
    input_widget.placeholder = "Ask Subconscious anything..."
    input_widget.value = ""
    input_widget.focus()

  async def on_input_submitted(self, event: Input.Submitted) -> None:
    if event.input.id != "main_input":
      return
    
    message = event.value.strip()
    
    if self.is_setup_mode:
      # If the user just pressed enter on the default path or typed a new one
      path = pathlib.Path(message) if message else self.config.data_dir
      self.config.data_dir = path
      self.config.save()
      
      log = self.query_one("#main_log", SelectableRichLog)
      log.write(f"\n[bold green]Config saved to:[/bold green] {path / 'config.yaml'}")
      self.initialize_ui(show_logo=False)
      return

    if not message:
      return

    log = self.query_one("#main_log", SelectableRichLog)
    log.write(f"\n[bold cyan]You:[/bold cyan] {message}")

    # Clear the input
    self.query_one("#main_input", Input).value = ""

    # Simple echo/placeholder for engine response
    log.write(f"[bold green]Subconscious:[/bold green] Processing [italic]{message}[/italic]...")

    # Simulate engine work
    await asyncio.sleep(0.5)
    log.write(f"[bold green]Subconscious:[/bold green] Analysis complete. Waiting for next instruction.")


async def start_tui(config: Config):
  """ TUI startup logic with Textual """
  app = SubconsciousApp(config)
  await app.run_async()
