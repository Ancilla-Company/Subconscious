# Changelog

All notable changes to Subconscious will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.1.7] — 2026-04-25

### Changed

- Initial and startup logging ouput dev and prod versions

### Fixed

- Fixed assets directory refrence bug

---

## [0.1.0] — 2026-04-25

### Added

- Initial public release of Subconscious
- Local-first AI agent platform with multi-platform support (Desktop, Web, Mobile)
- Support for 10+ AI providers: OpenAI, Anthropic, Google Gemini, Ollama, DeepSeek, Mistral, Groq, Grok, Hugging Face
- Built-in agent tools: Terminal, FileSystem, Calculator, Clipboard, Contacts, Time, Weather, Web Tools, Notes, Todo, Memory
- Workspaces and Threads for organizing conversations and tasks
- Desktop application (Windows) via Flet + PyInstaller
- SQLite database with async SQLAlchemy (`aiosqlite`)
- Encrypted secrets and API key management via system keyring
- BYOK (Bring Your Own Keys) — connect any provider with your own API key
- Agentic file attachment support — inline context from PDF, DOCX, XLSX files
- Auto-update mechanism with one-button seamless update
- System tray support (Windows)
- CLI entry point: `subconscious`
- PyPI distribution: `pip install subconscious-chat`

---

[0.1.0]: https://github.com/Ancilla-Company/Subconscious/releases/tag/v0.1.0
