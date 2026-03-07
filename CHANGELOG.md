## [Unreleased]

### Added
- Headless Rails 8.1 app (API-only, no views/assets/Action Cable)
- `anima install` command — creates ~/.anima/ tree, per-environment credentials, systemd user service
- `anima start` command — runs db:prepare and boots Rails
- SQLite databases, logs, tmp, and credentials stored in ~/.anima/
- Environment validation (development, test, production)

## [0.0.1] - 2026-03-06

- Initial gem scaffold with CI and RubyGems publishing
