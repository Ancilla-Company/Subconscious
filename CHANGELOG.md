# Changelog


All notable changes to Subconscious will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.1.10]

### Added (Unreleased)

- Internet connectivity tool
- File search tool
- Echo agent for dev mode testing

### Changed (Unreleased)

- Updated image tools to accept vector files like svg

### Fixed (Unreleased)

- Self update bug
- Manifest format update for winget

---

## [0.1.9] - 2025-05-04

### Added

- Windows version distributed via winget

---

## [0.1.8] — 2026-05-04

### Changed

- Streaming LLM response updates
- Typing placeholder & animation (currently broken)
- Image resize tool
- Terminal session tool
- Dev mode tag in titlebar

### Fixed

- Self update for python distro

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

