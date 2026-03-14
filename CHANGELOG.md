## [Unreleased]

### Added
- Tmux-style focus switching — `Ctrl+A ↑` enters chat scrolling mode with yellow border, `Escape` returns to input; arrow keys and Page Up/Down scroll chat, mouse scroll works in both modes (#87)
- Bash-style input history — press ↑ at top of input to recall previous messages, ↓ to navigate forward; original draft restored when exiting history (#87)
- Real-time event broadcasting via `Event::Broadcasting` concern — `after_create_commit` and `after_update_commit` callbacks broadcast decorated payloads with database ID and action type to the session's ActionCable stream (#91)
- TUI `MessageStore` ID-indexed updates — events with `action: "update"` replace existing entries in-place (O(1) lookup) without changing display order
- `CountEventTokensJob` triggers broadcast — uses `update!` so token count updates push to connected clients in real time
- Connection status constants in `CableClient` — replaces magic strings with named constants for protocol message types

### Changed
- Connection status indicator simplified — emoji-only `🟢` for normal state, descriptive text only for abnormal states (#80)
- `STATUS_STYLES` structure simplified from `{label, fg, bg}` to `{label, color}` (#80)
- `ActionCableBridge` removed — broadcasting moved from EventBus subscriber to AR callbacks, eliminating the timing gap where events were broadcast before persistence
- `SessionChannel` history includes event IDs for client-side correlation

### Fixed
- TUI showed empty chat on reconnect — message store was cleared _after_ history arrived because `confirm_subscription` comes after `transmit` in Action Cable protocol; now clears on "subscribing" before history (#82)

## [0.2.1] - 2026-03-13

### Added
- TUI view mode switching via `Ctrl+a → v` — cycle between Basic, Verbose, and Debug (#75)
- Draper EventDecorator hierarchy — structured data decorators for all event types (#74)
- Decorators return structured hashes (not strings) for transport-layer filtering (#86)
- Basic mode tool call counter — inline `🔧 Tools: X/Y ✓` aggregation (#73)
- Verbose view mode rendering — timestamps, tool call previews, system messages (#76)
- Tool call previews: bash `$ command`, web_get `GET url`, generic JSON fallback
- Tool response display: truncated to 3 lines, `↩` success / `❌` failure indicators
- Debug view mode — token counts per message, full tool args/responses, tool use IDs (#77)
- Estimated token indicator (`~` prefix) for events not yet counted by background job
- View mode persisted on Session model — survives TUI disconnect/reconnect
- Mode changes broadcast to all connected clients with re-decorated viewport

### Fixed
- Newlines in LLM responses collapsed into single line in rendered view modes
- Loading state stuck after view mode switch — input blocked with "Thinking..."

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
