import uuid
from datetime import datetime
from sqlalchemy.orm import declarative_base, relationship
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text


Base = declarative_base()


class Workspace(Base):
  __tablename__ = 'workspaces'

  id = Column(Integer, primary_key=True, autoincrement=True)
  name = Column(String, nullable=False)
  subconscious_id = Column(String, nullable=False)
  uuid = Column(String, default=str(uuid.uuid4()))
  created_at = Column(DateTime, default=datetime.now)

  threads = relationship("Thread", back_populates="workspace", cascade="all, delete-orphan")


class Thread(Base):
  __tablename__ = 'threads'

  id = Column(Integer, primary_key=True, autoincrement=True)
  workspace_id = Column(Integer, ForeignKey('workspaces.id'), nullable=False)
  title = Column(String)
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
  """
  __tablename__ = 'app_state'

  id = Column(Integer, primary_key=True, autoincrement=True)
  key = Column(String, nullable=False, unique=True)
  value = Column(String, nullable=False)

