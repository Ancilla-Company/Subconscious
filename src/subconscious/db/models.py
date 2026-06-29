import re
import uuid
import bcrypt
from datetime import datetime
from sqlalchemy.ext.hybrid import hybrid_property
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text
from sqlalchemy.orm import declarative_base, relationship, mapped_column, Mapped


Base = declarative_base()


class Networks(Base):
  """ List of Subconscious Networks """
  __tablename__ = 'networks'

  id = Column(Integer, primary_key=True, autoincrement=True)
  uuid = Column(String, default=str(uuid.uuid4()), unique=True)
  name = Column(String, nullable=False)
  description = Column(Text)
  default_workspace_uuid = Column(String, nullable=True)
  _passphrase: Mapped[bytes] = mapped_column("passphrase", nullable=True)
  created_at = Column(DateTime, default=datetime.now)

  @hybrid_property
  def passphrase(self) -> bytes:
    return self._passphrase
  
  @passphrase.setter
  def passphrase(self, string: str) -> None:
    if not re.match(r'^(?=.*\d)(?=.*[a-z])(?=.*[A-Z]).{8,}$', string):
      raise ValueError("U014")
    self._passphrase = bcrypt.hashpw(string.encode('utf-8'), bcrypt.gensalt())
  
  @passphrase.expression
  def passphrase(cls) -> bytes:
    return cls._passphrase

class Workspace(Base):
  __tablename__ = 'workspaces'

  id = Column(Integer, primary_key=True, autoincrement=True)
  name = Column(String, nullable=False)
  description = Column(String, nullable=True)
  network_id = Column(Integer, ForeignKey('networks.id'), nullable=False)
  uuid = Column(String, default=str(uuid.uuid4()))
  tools_config = Column(Text, nullable=True)
  skills_config = Column(Text, nullable=True)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)
  created_at = Column(DateTime, default=datetime.now)

  threads = relationship("Thread", back_populates="workspace", cascade="all, delete-orphan")


class Thread(Base):
  __tablename__ = 'threads'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  title = Column(String)
  description = Column(String, nullable=True)
  default_model_id = Column(String, nullable=True, default="default") # NULL also means default
  tools_config = Column(Text, nullable=True)
  skills_config = Column(Text, nullable=True)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)
  created_at = Column(DateTime, default=datetime.now)

  workspace = relationship("Workspace", back_populates="threads")
  messages = relationship("Message", back_populates="thread", cascade="all, delete-orphan")


class Message(Base):
  __tablename__ = 'messages'

  id = Column(Integer, primary_key=True, autoincrement=True)
  thread_id = Column(Integer, ForeignKey('threads.id'), nullable=False)
  role = Column(String, nullable=False) # user, agent, system
  content = Column(Text, nullable=False)
  created_at = Column(DateTime, default=datetime.now)

  thread = relationship("Thread", back_populates="messages")


class AppState(Base):
  """ Store the state of the application, such as current workspace and thread
      Using a key value format to store arbitrary data
      Store default workspace
  """
  __tablename__ = 'app_state'

  id = Column(Integer, primary_key=True, autoincrement=True)
  key = Column(String, nullable=False)
  value = Column(String, nullable=False)
  tag = Column(String, nullable=True) # To categorize state/settings


class TodoItem(Base):
  """
  A to-do item created by the user or agent, scoped to a workspace.
  Status values: 'open', 'in_progress', 'done', 'cancelled'
  Priority values: 'low', 'normal', 'high', 'urgent'
  """
  __tablename__ = 'todo_items'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  thread_id = Column(Integer, ForeignKey('threads.id'), nullable=True) # optional origin thread
  title = Column(String, nullable=False)
  notes = Column(Text, nullable=True)
  status = Column(String, nullable=False, default='open')
  priority = Column(String, nullable=False, default='normal')
  due_date = Column(DateTime, nullable=True)
  created_at = Column(DateTime, default=datetime.now)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)


class WorkspaceMemory(Base):
  """
  Long-term key/value memory scoped to a workspace.
  The agent can store and retrieve facts that should persist across threads.
  """
  __tablename__ = 'workspace_memory'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  key = Column(String, nullable=False)        # e.g. "user_name", "preferred_language"
  value = Column(Text, nullable=False)
  source_thread_id = Column(Integer, ForeignKey('threads.id'), nullable=True)
  created_at = Column(DateTime, default=datetime.now)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)


class Note(Base):
  """
  User/agent-created notes scoped to a workspace.
  Unlike memory these are human-readable documents, not key/value pairs.
  """
  __tablename__ = 'notes'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  title = Column(String, nullable=False)
  content = Column(Text, nullable=False, default='')
  tags = Column(String, nullable=True)        # comma-separated tag list
  created_at = Column(DateTime, default=datetime.now)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)


class Contact(Base):
  """
  Simple contact book scoped to a workspace.
  """
  __tablename__ = 'contacts'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  name = Column(String, nullable=False)
  email = Column(String, nullable=True)
  phone = Column(String, nullable=True)
  notes = Column(Text, nullable=True)
  created_at = Column(DateTime, default=datetime.now)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)


class SkillRegistry(Base):
  """
  Registry of installed skills (packages containing agent capabilities).
  Skills are stored as packages in the config data folder under skills/<uuid>.
  Source can be a URL (git/zip download), a local zip file, or a local folder.
  Status values: 'pending', 'valid', 'invalid', 'error'
  """
  __tablename__ = 'skill_registry'

  id = Column(Integer, primary_key=True, autoincrement=True)
  uuid = Column(String, default=lambda: str(uuid.uuid4()), unique=True)
  name = Column(String, nullable=False)
  alias = Column(String, nullable=True)
  description = Column(Text, nullable=True)
  source = Column(String, nullable=False)                         # URL, zip path, or folder path
  source_type = Column(String, nullable=False, default='folder')  # 'url', 'zip', 'folder'
  install_path = Column(String, nullable=True)                    # resolved path inside data_dir/skills/
  version = Column(String, nullable=True)
  status = Column(String, nullable=False, default='pending')      # pending, valid, invalid, error
  required_tools = Column(Text, nullable=True)                    # JSON list of tool slugs declared in skill.json
  metadata_json = Column(Text, nullable=True)                     # raw skill.json / manifest contents
  created_at = Column(DateTime, default=datetime.now)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)


class ToolRegistry(Base):
  """
  Registry of configured tools (scripts, MCP servers, REST/API endpoints).
  Tool types: 'script' (Python/JS/TS), 'mcp' (MCP server), 'api' (REST endpoint).
  Auth types: None / 'api_key' / 'oauth'
  API keys are stored encrypted in the keyring data file (keyed by uuid).
  Status values: 'active', 'disabled', 'error'
  """
  __tablename__ = 'tool_registry'

  id = Column(Integer, primary_key=True, autoincrement=True)
  uuid = Column(String, default=lambda: str(uuid.uuid4()), unique=True)
  name = Column(String, nullable=False)
  alias = Column(String, nullable=True)
  description = Column(Text, nullable=True)
  tool_type = Column(String, nullable=False, default='script')    # 'script', 'mcp', 'api'
  # Script-specific
  script_path = Column(String, nullable=True)
  script_language = Column(String, nullable=True)                 # 'python', 'javascript', 'typescript'
  # MCP / API endpoint
  endpoint_url = Column(String, nullable=True)
  # Auth
  auth_type = Column(String, nullable=True)                       # None, 'api_key', 'oauth'
  auth_env_var = Column(String, nullable=True)                    # env var name holding the key at runtime
  status = Column(String, nullable=False, default='active')       # active, disabled, error
  created_at = Column(DateTime, default=datetime.now)
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)
