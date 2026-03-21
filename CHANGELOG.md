## [Unreleased]

### Added
- **ToolDecorator content pipeline** — new server-side decorator layer that transforms tool responses for LLM consumption before they enter the event stream; `ToolDecorator` base class with factory dispatch by tool name, extensible for any tool (#253)
- **WebGetToolDecorator** — Content-Type → method dispatch DSL: `text/html` converts to Markdown (strips scripts, styles, nav, footer, ads), `application/json` compresses to TOON (~40% token savings), unknown types pass through; metadata tags (`[Converted: HTML → Markdown]`) inform the LLM about transformations (#253)
- `Tools::WebGet` now returns structured `{body:, content_type:}` result, preserving HTTP Content-Type header for format-specific decoration (#253)
- **TUI performance logging** — `--debug` flag enables frame-level timing to `log/tui_performance.log` with per-phase measurements (build_lines, paragraph, line_count, sidebar); uses `TUI::PerformanceLogger` with monotonic clock and 5MB log rotation (#182)
- **TUI render caching** — `MessageStore` version tracking eliminates O(n×m) per-frame line rebuilds; cached message lines and `line_count` results are reused across frames until content actually changes; scrolling no longer triggers any Ruby-side computation, running at ~1.8ms/frame regardless of message count (#182)
- **Bounce Back** — failed user messages return to the input field instead of persisting as orphans; event creation and LLM delivery are wrapped in a database transaction so both succeed or fail atomically; on failure, a transient `BounceBack` event notifies clients to restore the text and display a flash message (#236)
- Event-driven job scheduling — `AgentDispatcher` subscriber reacts to non-pending `UserMessage` emissions by scheduling `AgentRequestJob`, replacing the imperative `perform_later` call in the channel (#236)
- `TransientBroadcaster` subscriber — bridges non-persisted events (like `BounceBack`) to ActionCable for client delivery (#236)
- `Event#broadcast_now!` — manual broadcast inside transactions where `after_create_commit` is deferred, providing optimistic UI (#236)
- `AgentLoop#deliver!` — makes the first LLM API call inside the Bounce Back transaction and caches the response so `#run` can continue without duplicating work (#236)
- `LLM::Client#chat_with_tools` accepts `first_response:` parameter to skip the first API call when a pre-fetched response is available (#236)
- TUI flash message system (`TUI::Flash`) — ephemeral notifications at the top of the chat pane with auto-dismiss and keypress dismiss; supports error (red), warning (yellow), and info (blue) levels (#236)
- TUI bounce back handling — removes phantom user message from chat, restores text to input buffer, shows flash with error context (#236)
- HUD toggle — collapsible info panel via `C-a → h` with redesigned layout: session name, goals with descriptions and status icons (`●` active, `◐` in-progress, `✓` completed), skills, workflow, sub-agents with activity indicators (`●` running, `◌` idle), and a bottom status bar showing connection state and view mode; panel occupies 1/3 screen width when visible, input border shows `C-a → h HUD` hint when hidden (#226)
- Real-time sub-agent tracking — HUD displays child sessions with processing state; broadcasts flow from `SpawnSubagent`/`SpawnSpecialist` on creation and `AgentRequestJob` on processing state changes (#226)
- `session_changed` payload now includes `children` array for sessions with sub-agents (#226)
- Client-side TUI decorator layer — per-tool rendering with tool-specific icons, colors, and formatting; `BaseDecorator` factory dispatches to `BashDecorator`, `ReadDecorator`, `EditDecorator`, `WriteDecorator`, `WebGetDecorator`, and `ThinkDecorator` (#227)
- Server-side `ToolResponseDecorator` now includes `tool` field in verbose/debug output for client-side per-tool dispatch (#227)
- Server-side `ToolCallDecorator#format_input` extended with tool-specific formatting for `read`, `edit`, and `write` (#227)
- `anima update` command — upgrades the gem and merges new config keys into existing `config.toml` without overwriting user-customized values — `--migrate-only` flag to skip gem upgrade (#155)
- Directory-based skills format — `skills/skill-name/SKILL.md` with optional `references/` and `examples/` subdirectories alongside flat `.md` files (#152)
- Import 6 marketplace skills: activerecord, rspec, draper-decorators, dragonruby, ratatui-ruby, mcp-server (#152)
- Tmux-style focus switching — `C-a ↑` enters chat scrolling mode with yellow border, `Escape` returns to input; arrow keys and Page Up/Down scroll chat, mouse scroll works in both modes (#87)
- Bash-style input history — press ↑ at top of input to recall previous messages, ↓ to navigate forward; original draft restored when exiting history (#87)
- Real-time event broadcasting via `Event::Broadcasting` concern — `after_create_commit` and `after_update_commit` callbacks broadcast decorated payloads with database ID and action type to the session's ActionCable stream (#91)
- TUI `MessageStore` ID-indexed updates — events with `action: "update"` replace existing entries in-place (O(1) lookup) without changing display order
- `CountEventTokensJob` triggers broadcast — uses `update!` so token count updates push to connected clients in real time
- Connection status constants in `CableClient` — replaces magic strings with named constants for protocol message types
- VCR test infrastructure for recording and replaying external HTTP interactions — cassettes for Anthropic API success, 401, 403, 429, 500, and 529 responses; `spec/support/vcr.rb` auto-loaded via `rails_helper.rb`; API keys filtered from cassettes; `:new_episodes` in dev, `:none` in CI (#190)

### Changed
- `Persister` skips non-pending `user_message` events — `AgentRequestJob` now owns their persistence lifecycle inside a transaction (#236)
- `SessionChannel#speak` no longer calls `AgentRequestJob.perform_later` directly — job scheduling is event-driven via `AgentDispatcher` (#236)
- Generic `"error"` action from server now shows a flash message in TUI instead of being silently ignored (#236)
- Connection status indicator simplified — emoji-only `🟢` for normal state, descriptive text only for abnormal states (#80)
- `STATUS_STYLES` structure simplified from `{label, fg, bg}` to `{label, color}` (#80)
- `ActionCableBridge` removed — broadcasting moved from EventBus subscriber to AR callbacks, eliminating the timing gap where events were broadcast before persistence
- `SessionChannel` history includes event IDs for client-side correlation

### Fixed
- OAuth tokens rejected without Claude Code identity prefix — Anthropic requires the `system` parameter in array-of-blocks format with the identity passphrase as the first block for Sonnet/Opus via OAuth subscription tokens; without it, `/v1/messages` returns 400 (#233)
- API 500 errors no longer trigger the token re-entry prompt loop — transient errors (5xx, 429, timeout, network) during token validation save the token and show a warning instead of blocking the user; `validate_credentials!` now wraps network exceptions as `TransientError` consistently with `create_message`/`count_tokens` (#190)
- TUI showed empty chat on reconnect — message store was cleared _after_ history arrived because `confirm_subscription` comes after `transmit` in Action Cable protocol; now clears on "subscribing" before history (#82)

## [0.2.1] - 2026-03-13

### Added
- TUI view mode switching via `C-a → v` — cycle between Basic, Verbose, and Debug (#75)
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
- TUI resumes last session on startup, `C-a → n` creates a new session
- Event system using Rails Structured Event Reporter (`Rails.event`)
- Five event types: `system_message`, `user_message`, `agent_message`, `tool_call`, `tool_response`
- `Events::Bus` — thin wrapper around `Rails.event` for emitting and subscribing to Anima events
- `Events::Subscribers::MessageCollector` — in-memory subscriber that collects displayable messages
- Chat screen refactored from raw array to event-driven architecture
- TUI chat screen with LLM integration — in-memory message array, threaded API calls
- Chat input with character validation, backspace, Enter to submit
- Loading indicator — "Thinking" status bar mode, grayed-out input during LLM calls
- New session command (`C-a → n`) clears conversation
- Error handling — API failures displayed inline as chat messages
- Anthropic API subscription token authentication
- LLM client (raw HTTP to Anthropic API)
- TUI scaffold with RatatuiRuby — tmux-style `C-a` command mode, sidebar, status bar
- Headless Rails 8.1 app (API-only, no views/assets)
- `anima install` command — creates ~/.anima/ tree, per-environment credentials, systemd user service
- `anima start` command — runs db:prepare and boots Rails via Foreman
- Systemd user service — auto-enables and starts brain on `anima install`
- SQLite databases, logs, tmp, and credentials stored in ~/.anima/
- Environment validation (development, test, production)

## [0.0.1] - 2026-03-06

- Initial gem scaffold with CI and RubyGems publishing
