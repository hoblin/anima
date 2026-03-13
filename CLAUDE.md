Follow user instructions precisely.

You are the sole codeowner. There is no tech debt someone else will fix for you. Apply the Boy Scout Rule: leave every file cleaner than you found it. Fix code smells, not just the task at hand.

Use YARD to document business logic and external API. Keep documentation up to date when changing code.

Research spikes should describe what we need, not where to look. Prescribing solutions defeats the purpose of a research spike.

Always fix flaky tests. Never skip, mark pending, or work around them — fix the root cause.

Do not add "defense-in-depth" rescue clauses or fallback logic. Silently swallowing exceptions hides bugs, violates the Single Responsibility Principle, and masks missing business logic. Let exceptions propagate — they signal that a use case is not covered. Fix the gap in logic instead of papering over it.

The development environment is fully configured (LLM API keys, credentials, dependencies). Don't ask — just run things.

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

## Testing TUI in tmux

RatatuiRuby requires a real PTY. Background processes (`&`) and `script` don't work reliably. Use tmux to smoke-test the TUI:

```bash
# Launch TUI in a detached tmux session (connects to dev brain on 42135)
tmux new-session -d -s anima-test -x 120 -y 30 './exe/anima tui --host localhost:42135'

# Wait for render, then capture the screen
sleep 1 && tmux capture-pane -t anima-test -p

# Send keystrokes (add sleep 0.3-0.5 between send and capture for rendering)
tmux send-keys -t anima-test C-a        # Ctrl+a
tmux send-keys -t anima-test s           # letter key
tmux send-keys -t anima-test Escape      # Esc

# Capture specific areas
tmux capture-pane -t anima-test -p | head -5   # top of screen
tmux capture-pane -t anima-test -p | tail -2   # status bar

# Clean up
tmux kill-session -t anima-test
```

If the TUI crashes on startup, append `; sleep 30` to the command to keep the session alive for error inspection.

Always clean up tmux sessions when done. Use `anima-test` as the session name for consistency.

**Important:** Use `./exe/anima` (not `bundle exec anima`) to test local code changes. The exe uses `require_relative` so it loads local `lib/` directly. `bundle exec` may load the installed gem version instead.

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
