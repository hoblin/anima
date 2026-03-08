Follow user instructions precisely.

## Testing TUI in tmux

RatatuiRuby requires a real PTY. Background processes (`&`) and `script` don't work reliably. Use tmux to smoke-test the TUI:

```bash
# Launch TUI in a detached tmux session
tmux new-session -d -s anima-test -x 120 -y 30 'bundle exec anima tui'

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
