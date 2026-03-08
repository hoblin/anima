## [Unreleased]

### Added
- TUI chat screen with LLM integration — in-memory message array, threaded API calls
- Chat input with character validation, backspace, Enter to submit
- Loading indicator — "Thinking" status bar mode, grayed-out input during LLM calls
- New session command (`Ctrl+a > n`) clears conversation
- Error handling — API failures displayed inline as chat messages
- Anthropic API subscription token authentication
- LLM client (raw HTTP to Anthropic API)
- TUI scaffold with RatatuiRuby — tmux-style `Ctrl+a` command mode, sidebar, status bar
- Headless Rails 8.1 app (API-only, no views/assets/Action Cable)
- `anima install` command — creates ~/.anima/ tree, per-environment credentials, systemd user service
- `anima start` command — runs db:prepare and boots Rails
- SQLite databases, logs, tmp, and credentials stored in ~/.anima/
- Environment validation (development, test, production)

## [0.0.1] - 2026-03-06

- Initial gem scaffold with CI and RubyGems publishing
