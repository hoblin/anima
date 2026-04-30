# frozen_string_literal: true

# Diagnostic logger for the PendingMessage broadcast / drain pipeline.
# Tracks every broadcast emitted by {PendingMessage}, every Message
# broadcast emitted by {Events::Subscribers::MessageBroadcaster}, and
# the round membership decisions made by {DrainJob}, so per-PM
# mismatches between server emits and TUI receipts can be diagnosed
# without restarting the agent.
#
# Investigative tool for issue #481 (TUI pending tool responses leak):
# pair the server's `log/broadcast.log` with the TUI's
# `log/tui_broadcast.log` to count creates/removes/messages per batch
# round and identify any per-PM mismatch.
module BroadcastDiagnostics
  # Dev-only logger that writes to log/broadcast.log.
  # In non-development environments returns a null logger so call
  # sites don't need conditionals.
  #
  # @return [Logger]
  def self.logger
    @logger ||= build_logger
  end

  def self.build_logger
    return Logger.new(File::NULL) unless Rails.env.development?

    Logger.new(Rails.root.join("log", "broadcast.log")).tap do |log|
      log.formatter = proc { |severity, time, _progname, msg|
        "[#{time.strftime("%H:%M:%S.%L")}] #{severity}  #{msg}\n"
      }
    end
  end
  private_class_method :build_logger
end
