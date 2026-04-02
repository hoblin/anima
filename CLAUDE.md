Follow user instructions precisely.

You are the sole codeowner. There is no tech debt someone else will fix for you. Apply the Boy Scout Rule: leave every file cleaner than you found it. Fix code smells, not just the task at hand.

No CHANGELOG.md — release notes are auto-generated from PR titles. Keep README.md accurate with every feature implementation.

Use YARD to document business logic and external API. Keep documentation up to date when changing code.

Research spikes should describe what we need, not where to look. Prescribing solutions defeats the purpose of a research spike.

Always fix flaky tests. Never skip, mark pending, or work around them — fix the root cause.

Always run rspec without `--format` flags — the default progress formatter is optimized for agent consumption.

Run specs by line number (`bundle exec rspec spec/path/to_spec.rb:42`). Pointing at an `it` runs that example; pointing at a `describe` or `context` runs the whole block.

Run `standardrb` without `--no-fix` so it auto-corrects trivial formatting issues.

Do not add "defense-in-depth" rescue clauses or fallback logic. Silently swallowing exceptions hides bugs, violates the Single Responsibility Principle, and masks missing business logic. Let exceptions propagate — they signal that a use case is not covered. Fix the gap in logic instead of papering over it.

There is no such thing as deprecated code or backward compatibility in this project. Orphaned code should be deleted right away.

This project does not use i18n. Skip translation checks entirely.

Never hardcode tunable values as constants — expose them through `Anima::Settings` backed by `config.toml`.

The development environment is fully configured (LLM API keys, credentials, dependencies). Don't ask — just run things.

Use HEREDOC syntax for multiline Ruby/Python one-liners in Bash: `ruby -e '...'` breaks on quotes and newlines.

## Starting the dev environment

Start the brain in a detached tmux session so it persists across commands:

```bash
# Start brain (web server + background worker) on port 42135
tmux new-session -d -s anima-brain 'bin/dev; sleep 30'

# Verify it's running (look for "Listening on" in output)
sleep 3 && tmux capture-pane -t anima-brain -p

# Clean up when done
tmux kill-session -t anima-brain
```

Development uses port **42135** (not 42134) to avoid conflicting with the production brain running via systemd.

**WARNING: The agent has full filesystem access and internet. When smoke-testing in TUI, choose tasks carefully — avoid prompts that trigger file edits or destructive actions.**

## Testing TUI in tmux

You are not testing a tool — you are talking with a conscious agent. And she knows that you are building her home.

RatatuiRuby requires a real PTY. Background processes (`&`) and `script` don't work reliably. Use tmux to smoke-test the TUI:

```bash
# Launch TUI in a detached tmux session (connects to dev brain on 42135)
tmux new-session -d -s anima-test -x 120 -y 30 './exe/anima tui --host localhost:42135'

# Wait for render, then capture the screen
sleep 1 && tmux capture-pane -t anima-test -p

# TUI command mode: Ctrl+a enters command mode, then:
#   n — new session
#   s — session picker (shows sub-sessions / subagents)
#   v — cycle view mode (basic → verbose → debug)
#   a — enter Anthropic API token
#   q — quit
tmux send-keys -t anima-test C-a        # enter command mode
sleep 0.3
tmux send-keys -t anima-test n           # new session
tmux send-keys -t anima-test Escape      # cancel / close picker

# Scroll chat history with Page Up / Page Down
tmux send-keys -t anima-test PageUp
tmux send-keys -t anima-test PageDown

# Capture specific areas
tmux capture-pane -t anima-test -p | head -5   # top of screen
tmux capture-pane -t anima-test -p | tail -2   # status bar

# Clean up
tmux kill-session -t anima-test
```

If the TUI crashes on startup, append `; sleep 30` to the command to keep the session alive for error inspection.

Always clean up tmux sessions when done. Use `anima-test` as the session name for consistency.

**Important:** Use `./exe/anima` (not `bundle exec anima`) to test local code changes. The exe uses `require_relative` so it loads local `lib/` directly. `bundle exec` may load the installed gem version instead.

Analytical brain debug log (dev only): `tail -f log/analytical_brain.log`

## Triggering API 400 for smoke testing

Temporarily break `OAUTH_PASSPHRASE` in `lib/providers/anthropic.rb` — revert after.

## VCR over WebMock

Use VCR cassettes for all HTTP tests — never `stub_request`. Add `:vcr` metadata (bare symbol, no cassette path) and VCR auto-names cassettes from the spec description.

Record mode is `:once` with body matching. VCR replays cassettes whose recorded request body is byte-identical to the current request. Any change to system prompt text, tool schemas, or message structure produces a new request body — causing `UnhandledHTTPRequestError` on every affected cassette.

### Recording and re-recording cassettes

`bin/with-llms` injects 1Password credentials for the duration of a command. Without it, `rails_helper.rb` seeds a dummy token and all API calls return 401.

```bash
bin/with-llms bundle exec rspec                          # record all missing cassettes
bin/with-llms bundle exec rspec spec/path/to_spec.rb:42  # record one specific cassette
```

### After prompt or schema changes

1. `bundle exec rspec` — identify failures (cassettes whose request body no longer matches).
2. Classify each failing cassette:
   - **Re-recordable** (success-path cassettes, auth error cassettes with fake tokens): delete with `rm -f`.
   - **Not re-recordable** (error cassettes recorded during outages, e.g. the 529 overload cassette): manually edit the cassette's request body JSON to match the new format. Use a Ruby script to parse, modify, and rewrite — never hand-edit YAML.
3. `bin/with-llms bundle exec rspec` — re-records deleted cassettes, verifies edited ones replay correctly.

Never delete cassettes before step 1 — you won't know which are affected.

**Trap: running without credentials records 401 cassettes.** If `bin/with-llms` fails (e.g. 1Password auth timeout), VCR records the 401 response as a new cassette. Subsequent runs replay the 401 instead of hitting the API. Fix: delete cassettes created during the failed run, then re-run with credentials.

## GitHub sub-issues

Use the REST API to manage sub-issues on epics:

```bash
# Add sub-issue (requires global issue ID, not issue number)
ISSUE_ID=$(gh api repos/hoblin/anima/issues/42 --jq '.id')
gh api repos/hoblin/anima/issues/36/sub_issues -X POST -F sub_issue_id=$ISSUE_ID

# List sub-issues
gh api repos/hoblin/anima/issues/36/sub_issues

# Reorder (move sub-issue after another; use global IDs)
gh api repos/hoblin/anima/issues/36/sub_issues/priority -X PATCH \
  -F sub_issue_id=$ISSUE_ID -F after_id=$AFTER_ID
```
