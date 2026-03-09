## [Unreleased]

### Added
- `AgentLoop` service — decouples LLM orchestration from TUI; callable from background jobs, Action Cable channels, or TUI directly
- Session and event persistence to SQLite — conversations survive TUI restart
- `Session` model — owns an ordered event stream
- `Event` model — polymorphic type, JSON payload, auto-incrementing position
- `Events::Subscribers::Persister` — writes all events to SQLite as they flow through the bus
- TUI resumes last session on startup, `Ctrl+a > n` creates a new session
- `anima tui` now runs pending migrations automatically on launch
- Event system using Rails Structured Event Reporter (`Rails.event`)
- Five event types: `system_message`, `user_message`, `agent_message`, `tool_call`, `tool_response`
- `Events::Bus` — thin wrapper around `Rails.event` for emitting and subscribing to Anima events
- `Events::Subscribers::MessageCollector` — in-memory subscriber that collects displayable messages
- Chat screen refactored from raw array to event-driven architecture
- TUI chat screen with LLM integration — in-memory message array, threaded API calls
- Chat input with character validation, backspace, Enter to submit
- Loading indicator — "Thinking" status bar mode, grayed-out input during LLM calls
- New session command (`Ctrl+a > n`) clears conversation
- Error handling — API failures displayed inline as chat messages
- Anthropic API subscription token authentication
- LLM client (raw HTTP to Anthropic API)
- TUI scaffold with RatatuiRuby — tmux-style `Ctrl+a` command mode, sidebar, status bar
- Action Cable infrastructure with Solid Cable adapter for Brain/TUI WebSocket communication
- Headless Rails 8.1 app (API-only, no views/assets)
- `anima install` command — creates ~/.anima/ tree, per-environment credentials, systemd user service
- `anima start` command — runs db:prepare and boots Rails
- SQLite databases, logs, tmp, and credentials stored in ~/.anima/
- Environment validation (development, test, production)

## [0.0.1] - 2026-03-06

- Initial gem scaffold with CI and RubyGems publishing
