import re
import uuid
import bcrypt
from datetime import datetime
from sqlalchemy.ext.hybrid import hybrid_property
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text
from sqlalchemy.orm import declarative_base, relationship, mapped_column, Mapped


Base = declarative_base()


class Workspace(Base):
  __tablename__ = 'workspaces'

  id = Column(Integer, primary_key=True, autoincrement=True)
  name = Column(String, nullable=False)
  description = Column(String, nullable=True)
  network_id = Column(String, nullable=False)
  uuid = Column(String, default=str(uuid.uuid4()))
  updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)
  created_at = Column(DateTime, default=datetime.now)

  threads = relationship("Thread", back_populates="workspace", cascade="all, delete-orphan")


class Thread(Base):
  __tablename__ = 'threads'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  title = Column(String)
  description = Column(String, nullable=True)
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
  key = Column(String, nullable=False, unique=True)
  value = Column(String, nullable=False)


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
