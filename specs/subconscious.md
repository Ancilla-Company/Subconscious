# Spec Sheet: Subconscious

## 1. Overview

Subconscious is an open sourced distributed agentic engine, capable of running multiple simultaneous agents & instances on different machines.

## 2. Core Concepts

- **Workspace**: Represents a project or high-level domain (e.g., "Personal", "Work", "Product Launch").
- **Threads**: A chat thread with any number of participants, typcially agents and users.
- **Agents**: Autonomous entities in the chat threads.
- **Clone**: A running instance of Subconscious (light, full or client); light on partially syncs thread/workspace history
- **Client**: An interface that interacts with Subconscious
- **Hivemind**: A network of connected Clones similar to a blockchain, different hiveminds cannot interact
- **Tools**: Tools accessable by either agent or user e.g. MCP, Functions, UI plugins
- **To-Do**: Tasks the user or agent intends to complete

## 3. Architecture Requirements

### 3.1 CLI

- **Commands**: Based on the intended functionality
  - `subconscious`: Main entry point to start the engine and a TUI
  - `subconscious engine`: Starts only the engine no TUI
- **Flags**: Config flags
  - `--dev`: For development mode
  - `--config`: Specific the path to a config file

### 3.2 Deployment

- **Platforms:** Considered for Deployment
  - Python - PyPi
  - Windows - winget
  - Linux - apt-get
  - Docker - image
  - Podman - image
  - Mobile - app (light client)

### 3.3 Features & Libraries

- Programming Language - Python
- ORM - Sqlalchemy
- Database - Sqlite
- Thread & Agent Management - Pydantic AI
- Clone & Consensus Management - Ray & NATS
- Server - FastAPI
- TUI - Textual
- Permissions - OpenFGA
- Testing - PyTest

Should support the following:

- Agentic ReAct loops for long running tasks or arbitrary directives
- AG-UI for dynamic interfaces

### 3.4 Coding Style

- Async first
- 2 space indentation
- Simplicity - less is more
