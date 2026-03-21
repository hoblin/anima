# frozen_string_literal: true

require "logger"

module TUI
  # Frame-level performance logger for TUI render profiling.
  #
  # When enabled via `--debug`, logs timing data for each render phase
  # to `log/tui_performance.log`. Each frame produces one log line with
  # phase durations in milliseconds, enabling bottleneck identification.
  #
  # Uses monotonic clock to avoid wall-clock jitter.
  #
  # @example
  #   logger = PerformanceLogger.new(enabled: true)
  #   logger.start_frame
  #   logger.measure(:build_lines) { build_message_lines(tui) }
  #   logger.measure(:line_count) { widget.line_count(width) }
  #   logger.end_frame
  class PerformanceLogger
    LOG_PATH = "log/tui_performance.log"

    # @param enabled [Boolean] whether to actually log (no-op when false)
    def initialize(enabled: false)
      @enabled = enabled
      @phases = {}
      @frame_start = nil
      @frame_count = 0
      @logger = nil

      return unless @enabled

      @logger = Logger.new(LOG_PATH, 1, 5 * 1024 * 1024) # 5MB rotation
      @logger.formatter = proc { |_sev, time, _prog, msg| "#{time.strftime("%H:%M:%S.%L")} #{msg}\n" }
      @logger.info("TUI Performance Logger started — pid=#{Process.pid}")
    end

    # @return [Boolean] true when logging is active
    def enabled?
      @enabled
    end

    # Marks the beginning of a render frame.
    def start_frame
      return unless @enabled

      @frame_start = monotonic_now
      @phases = {}
    end

    # Measures a named phase within the current frame.
    # Returns the block's result so it can be used inline.
    #
    # @param name [Symbol] phase name (e.g. :build_lines, :line_count)
    # @yield the code to measure
    # @return [Object] the block's return value
    def measure(name)
      return yield unless @enabled

      start = monotonic_now
      result = yield
      @phases[name] = ((monotonic_now - start) * 1000).round(2)
      result
    end

    # Logs the completed frame with all phase timings.
    def end_frame
      return unless @enabled

      total = ((monotonic_now - @frame_start) * 1000).round(2)
      @frame_count += 1

      parts = @phases.map { |name, ms| "#{name}=#{ms}ms" }
      @logger.info("frame=#{@frame_count} total=#{total}ms #{parts.join(" ")}")
    end

    # Logs a one-off informational message (e.g. cache hit/miss).
    #
    # @param message [String]
    def info(message)
      @logger&.info(message)
    end

    private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
