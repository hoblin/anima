## [Unreleased]

### Added
- Verbose view mode rendering — `render_verbose` on all decorator subclasses (#76)
- Timestamped messages in verbose mode (`[HH:MM:SS] You:` / `[HH:MM:SS] Anima:`)
- Tool call previews: bash `$ command`, web_get `GET url`, generic JSON fallback
- Tool response display: truncated to 3 lines, `↩` success / `❌` failure indicators
- System messages visible in verbose mode (`[HH:MM:SS] [system] ...`)
- TUI view mode switching via `Ctrl+a → v` (#75)

## [0.2.0] - 2026-03-10

### Added
- Client-server architecture — Brain (Rails + Puma) runs as persistent service, TUI connects via WebSocket
- Action Cable infrastructure with Solid Cable adapter for Brain/TUI WebSocket communication
- `SessionChannel` — WebSocket channel for session management, message relay, and session switching
- Graceful TUI reconnection with exponential backoff (up to 10 attempts, max 30s delay)
- `AgentRequestJob` — background job for LLM agent loops with retry logic for transient failures (network errors, rate limits, server errors)
- Provider error hierarchy — `TransientError`, `RateLimitError`, `ServerError` for retry classification; `AuthenticationError` for immediate discard
- `AgentLoop#run` — retry-safe entry point for job callers; lets errors propagate for external retry handling
- `AgentLoop` service — decouples LLM orchestration from TUI; callable from background jobs, Action Cable channels, or TUI directly
- Session and event persistence to SQLite — conversations survive TUI restart
- `Session` model — owns an ordered event stream
- `Event` model — polymorphic type, JSON payload, auto-incrementing position
- `Events::Subscribers::Persister` — writes all events to SQLite as they flow through the bus
- TUI resumes last session on startup, `Ctrl+a > n` creates a new session
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
- Headless Rails 8.1 app (API-only, no views/assets)
- `anima install` command — creates ~/.anima/ tree, per-environment credentials, systemd user service
- `anima start` command — runs db:prepare and boots Rails via Foreman
- Systemd user service — auto-enables and starts brain on `anima install`
- SQLite databases, logs, tmp, and credentials stored in ~/.anima/
- Environment validation (development, test, production)

## [0.0.1] - 2026-03-06

- Initial gem scaffold with CI and RubyGems publishing
