---
description: Subconscious - Distributed agentic platform
applyTo: '**'
---

# Subconscious - Distributed AI Agent Platform

## Project Overview

Subconscious is a distributed agentic AI platform that enables users to create AI agents that run everywhere, on every device, simultaneously. It's an open-source alternative to ChatGPT, Claude, and other AI platforms, with a focus on local-first architecture, multi-platform support, and extensibility.

### Key Features
- **Local-First**: All data stored locally, no cloud dependency
- **Multi-Platform**: Desktop (Windows), Web, Mobile (planned), Terminal interfaces
- **Agentic Architecture**: AI agents with tools, memory, and autonomous capabilities
- **Extensible Tools**: Built-in tools for filesystem, terminal, web, calculator, etc.
- **Workspaces & Threads**: Organize conversations and tasks
- **BYOK (Bring Your Own Keys)**: Support for multiple AI providers (OpenAI, Anthropic, Gemini, etc.)
- **Auto-Updates**: Seamless update mechanism

## Codebase Structure

### Core Architecture

```
src/subconscious/
├── __init__.py              # Package initialization
├── __main__.py              # CLI entry point
├── agent.py                 # AgentManager - handles AI model configuration and agent creation
├── config.py                # Configuration management, secrets, data directories
├── constants.py             # Application constants and version info
├── engine.py                # Core Engine class - main application logic, DB operations, updates
├── cli/                     # Command-line interface
│   ├── __init__.py          # CLI parser and main() function
│   └── __main__.py          # CLI entry point
├── db/                      # Database layer
│   ├── models.py            # SQLAlchemy models (Networks, Workspaces, Threads, Messages, etc.)
│   └── session.py           # Database session management
├── gui/                     # Graphical User Interface (Flet-based)
│   ├── components/          # Reusable UI components
│   ├── screens/             # Main application screens
│   ├── frame.py             # Main application frame
│   ├── mainwindow.py        # Main window logic
│   ├── sidebar.py           # Navigation sidebar
│   ├── skeleton.py          # Application skeleton/layout
│   ├── titlebar.py          # Custom title bar
│   ├── tray.py              # System tray functionality
│   └── __init__.py
├── tools/                   # Built-in agent tools
│   ├── __init__.py          # ToolRegistry - manages available tools
│   ├── calculator.py        # Mathematical calculations
│   ├── clipboard.py         # Clipboard operations
│   ├── contacts.py          # Contact management
│   ├── filesystem.py        # File system operations
│   ├── memory.py            # Workspace memory management
│   ├── notes.py             # Note-taking functionality
│   ├── terminal.py          # Terminal command execution
│   ├── time_tools.py        # Date/time utilities
│   ├── todo.py              # Task management
│   └── weather.py           # Weather information
├── tui/                     # Terminal User Interface
├── web/                     # Web interface
├── mobile/                  # Mobile interface (planned)
├── api/                     # API endpoints (planned)
└── shared/                  # Shared utilities
```

### Entry Points

```
desktop_flet_ep.py           # Desktop application entry point (Flet Pack)
web_flet_ep.py              # Web application entry point
pyinstaller_ep.py           # PyInstaller entry point (legacy)
```

### Configuration & Build

```
pyproject.toml              # Project configuration, dependencies, build settings
requirements.txt            # Legacy requirements file
.github/workflows/          # CI/CD pipelines
├── release.yaml            # Release workflow (Python + Windows builds)
└── ...
```

### Data & Assets

```
src/subconscious/assets/    # Application assets (icons, images)
deploy/                     # Deployment artifacts
├── winget/                 # Winget package manifest
└── ...
```

## Key Components

### Engine (`engine.py`)
- **Purpose**: Core application logic and orchestration
- **Responsibilities**:
  - Database initialization and management
  - Agent lifecycle management
  - Tool registry integration
  - Update checking and notifications
  - Thread and workspace operations
  - File processing (PDF, DOCX, etc.)

### AgentManager (`agent.py`)
- **Purpose**: Manages AI model configurations and agent instantiation
- **Features**:
  - Support for 20+ AI providers (OpenAI, Anthropic, Gemini, Groq, etc.)
  - Environment variable management for API keys
  - Pydantic-AI agent creation with tool integration

### ToolRegistry (`tools/__init__.py`)
- **Purpose**: Registry and management of agent tools
- **Built-in Tools**:
  - `calculator`: Mathematical computations
  - `clipboard`: System clipboard operations
  - `contacts`: Contact book management
  - `filesystem`: File system navigation and operations
  - `memory`: Long-term workspace memory
  - `notes`: Note-taking and organization
  - `terminal`: Command execution
  - `time_tools`: Date/time utilities
  - `todo`: Task management
  - `weather`: Weather information retrieval
  - `web_tools`: Web browsing and scraping

### Database Models (`db/models.py`)
- **Networks**: Multi-user/network support
- **Workspaces**: Organizational containers for threads
- **Threads**: Conversation containers with messages
- **Messages**: Individual chat messages (user/agent/system)
- **TodoItem**: Task management
- **WorkspaceMemory**: Persistent key-value storage
- **Notes**: Document storage
- **Contacts**: Contact management
- **SkillRegistry**: Extensible skill/plugin system
- **ToolRegistry**: Custom tool configurations

### Configuration (`config.py`)
- **Data Directory**: Platform-specific local storage
- **Secrets Management**: Encrypted storage using Fernet
- **Keyring Integration**: Secure credential storage
- **YAML Configuration**: User preferences and settings

## Development Guidelines

### Python Code Standards
- **Type Hints**: Use type hints for all function parameters and return values
- **Async/Await**: Follow async/await patterns for I/O operations
- **Indentation**: 2 spaces (not 4)
- **Naming**: snake_case for variables/functions, PascalCase for classes
- **Imports**: Group imports (standard library, third-party, local)
- **No Hidden Imports**: Avoid dynamic imports for better readability and static analysis

### Architecture Patterns
- **Local-First**: All data stored locally, no cloud dependencies
- **Modular Design**: Clear separation between UI, engine, and tools
- **Dependency Injection**: EngineContext provides DB access to tools
- **Registry Pattern**: ToolRegistry and AgentManager for extensibility
- **Dataclass Configuration**: Config class for application settings

### Database Design
- **SQLite with aiosqlite**: Asynchronous database operations
- **SQLAlchemy ORM**: Object-relational mapping
- **Migration-Ready**: Versioned schema with relationships
- **Scoped Data**: Workspace-scoped entities for multi-tenancy

### UI Architecture (Flet)
- **Component-Based**: Reusable UI components
- **Screen-Based**: Organized screens for different views
- **Responsive Design**: Cross-platform compatibility
- **Custom Titlebar**: Native window integration

## Building and Deployment

### Development Setup
```bash
# Install dependencies
pip install -e .

# Run in development mode
python -m subconscious --dev gui
```

### Building
- **Desktop**: `flet pack` for Windows executable
- **Web**: `flet build web` for web deployment
- **Mobile**: `flet build aab` for Android (planned)
- **Python Package**: `python -m build` for PyPI distribution

### CI/CD
- **Release Workflow**: Automated builds for Python package and Windows executable
- **Winget Integration**: Automatic PR creation for Winget package updates
- **Multi-Platform**: Ubuntu (Python), Windows (desktop build)

## Key Files and Directories

### Must-Know Files
- `pyproject.toml`: Dependencies, scripts, Flet configuration
- `src/subconscious/engine.py`: Core application logic
- `src/subconscious/agent.py`: AI model and agent management
- `src/subconscious/tools/__init__.py`: Tool system architecture
- `src/subconscious/db/models.py`: Data schema
- `src/subconscious/config.py`: Configuration and secrets

### Important Directories
- `src/subconscious/gui/`: Desktop UI implementation
- `src/subconscious/tools/`: Agent capabilities
- `tests/`: Comprehensive test suite
- `.github/workflows/`: CI/CD pipelines
- `deploy/`: Packaging and distribution artifacts

## Extension Points

### Adding New Tools
1. Create tool module in `src/subconscious/tools/`
2. Define tool functions with proper type hints
3. Add `TOOLS = [...]` list in module
4. Tool functions receive `EngineContext` with DB access

### Adding New AI Providers
1. Update `_PROVIDER_MAP` in `agent.py`
2. Add provider prefix and environment variable
3. Test with AgentManager.build_agent()

### Adding New UI Screens
1. Create screen class in `src/subconscious/gui/screens/`
2. Implement screen logic with Flet components
3. Register in main navigation/sidebar

### Database Extensions
1. Add new model classes in `db/models.py`
2. Define relationships and constraints
3. Update Engine methods for CRUD operations

## Testing Strategy

### Test Structure
- **Unit Tests**: Individual component testing
- **Integration Tests**: Database and tool interactions
- **Async Testing**: Pytest-asyncio for async operations
- **Configuration Tests**: Config loading and validation

### Test Categories
- Tool functionality (calculator, filesystem, etc.)
- Database operations
- Configuration management
- Agent creation and execution

## Security Considerations

### Data Protection
- **Encryption**: Fernet encryption for sensitive data
- **Keyring**: OS-level secure credential storage
- **Local Storage**: No data sent to external servers

### API Key Management
- **Environment Variables**: Runtime API key injection
- **Encrypted Storage**: Secure model configuration storage
- **BYOK Policy**: User controls all API credentials

## Performance Considerations

### Database Optimization
- **Async Operations**: Non-blocking database access
- **Connection Pooling**: Efficient SQLite connections
- **Indexed Queries**: Optimized data retrieval

### Memory Management
- **Scoped Sessions**: Proper DB session lifecycle
- **Lazy Loading**: Efficient data loading patterns
- **Resource Cleanup**: Proper async task cancellation

This comprehensive overview should help you understand and contribute to the Subconscious codebase effectively. The architecture emphasizes modularity, extensibility, and local-first principles while maintaining cross-platform compatibility.