# frozen_string_literal: true

require "rails_helper"
require "shellwords"

# End-to-end test for non-blocking input with pending messages (#66).
# Launches the brain and TUI in tmux sessions, sends messages during
# active processing, and verifies the pending indicator appears and
# clears after delivery.
#
# Run with: bundle exec rspec --tag e2e
# Requires: tmux, dev environment configured (API keys, etc.)
RSpec.describe "Pending messages e2e", :e2e do
  before(:all) do
    skip "tmux not available" unless system("which tmux > /dev/null 2>&1")
    cleanup_sessions
    start_brain
    start_tui
  end

  after(:all) do
    cleanup_sessions unless skipped?
  end

  it "shows pending indicator during processing and clears it after delivery" do
    clock_icon = "\u{1F552}"

    # Wait for TUI to connect and render the input box
    wait_for_screen("Input", timeout: 15)

    # Send first message — triggers agent processing
    tmux_send_text("What is 2+2?")
    tmux_key("Enter")

    # Wait for processing to start (agent is thinking)
    wait_for_screen("Thinking", timeout: 15)

    # Send second message while processing — should become pending
    tmux_send_text("And what about 3+3?")
    tmux_key("Enter")

    # Verify pending indicator appears
    wait_for_screen(clock_icon, timeout: 10)

    # Wait for all processing to complete (both messages delivered)
    wait_for_screen_gone(clock_icon, timeout: 60)
  end

  # -- Helpers ---------------------------------------------------------------

  def brain_session = "anima-e2e-brain"

  def tui_session = "anima-e2e-test"

  def brain_port = 42_135

  def start_brain
    if port_listening?(brain_port)
      @brain_was_running = true
      return
    end

    system("tmux new-session -d -s #{brain_session} 'bin/dev; sleep 30'")
    wait_for_port(brain_port, timeout: 15)
  end

  def start_tui
    cmd = "./exe/anima tui --host localhost:#{brain_port}; sleep 30"
    system("tmux new-session -d -s #{tui_session} -x 120 -y 30 #{Shellwords.escape(cmd)}")
  end

  def cleanup_sessions
    system("tmux kill-session -t #{tui_session} 2>/dev/null")
    system("tmux kill-session -t #{brain_session} 2>/dev/null") unless @brain_was_running
  end

  def tmux_send_text(text)
    system("tmux send-keys -t #{tui_session} -l #{Shellwords.escape(text)}")
  end

  def tmux_key(key)
    system("tmux send-keys -t #{tui_session} #{key}")
  end

  def capture
    `tmux capture-pane -t #{tui_session} -p`
  end

  def wait_for_screen(text, timeout: 10)
    deadline = Time.now + timeout
    loop do
      screen = capture
      return if screen.include?(text)
      raise "Timed out after #{timeout}s waiting for #{text.inspect}. Screen:\n#{screen}" if Time.now > deadline
      sleep 0.3
    end
  end

  def wait_for_screen_gone(text, timeout: 30)
    deadline = Time.now + timeout
    loop do
      screen = capture
      return unless screen.include?(text)
      raise "Timed out after #{timeout}s waiting for #{text.inspect} to disappear. Screen:\n#{screen}" if Time.now > deadline
      sleep 1
    end
  end

  def port_listening?(port)
    system("ss -tlnp 2>/dev/null | grep -q ':#{port} '")
  end

  def wait_for_port(port, timeout: 15)
    deadline = Time.now + timeout
    loop do
      return if port_listening?(port)
      raise "Timed out after #{timeout}s waiting for port #{port}" if Time.now > deadline
      sleep 1
    end
  end

  def skipped?
    RSpec.current_example&.metadata&.dig(:skip)
  end
end
