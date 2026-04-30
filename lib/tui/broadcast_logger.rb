# frozen_string_literal: true

require "logger"
require_relative "settings"

module TUI
  # Diagnostic logger for ActionCable broadcasts received by the TUI.
  #
  # When enabled via `--broadcast-debug`, logs every dispatched WebSocket
  # message to `log/tui_broadcast.log` so server-side
  # `log/broadcast.log` (written by {BroadcastDiagnostics}) can be
  # paired against TUI receipts to find leaks per the issue #481
  # investigation.
  #
  # Counterpart to {TUI::PerformanceLogger} — both are no-op when
  # disabled, both write to a rotated log file.
  #
  # @example
  #   logger = BroadcastLogger.new(enabled: true)
  #   logger.info("recv pending_message_created PM=42")
  class BroadcastLogger
    # @param enabled [Boolean] whether to actually log (no-op when false)
    def initialize(enabled: false)
      @enabled = enabled
      @logger = nil

      return unless @enabled

      @logger = Logger.new(Settings.broadcast_log_path, 1, 5 * 1024 * 1024) # 5MB rotation
      @logger.formatter = proc { |_sev, time, _prog, msg| "[#{time.strftime("%H:%M:%S.%L")}] #{msg}\n" }
      @logger.info("TUI Broadcast Logger started — pid=#{Process.pid}")
    end

    # @return [Boolean] true when logging is active
    def enabled?
      @enabled
    end

    # @param message [String]
    def info(message)
      @logger&.info(message)
    end

    # @param message [String]
    def error(message)
      @logger&.error(message)
    end
  end
end
