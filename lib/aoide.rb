# frozen_string_literal: true

# Aoide — the muse of voice. The agent's main conversational loop:
# she takes the system prompt, recent messages, and tool registry, and
# turns each LLM response into dispatched tool executions. One of the
# Three Muses: Melete prepares, Aoide performs, Mneme remembers.
module Aoide
  # Dev-only logger that writes to log/aoide.log.
  # In non-development environments returns a null logger so
  # call sites don't need conditionals.
  #
  # @return [Logger]
  def self.logger
    @logger ||= build_logger
  end

  def self.build_logger
    return Logger.new(File::NULL) unless Rails.env.development?

    Logger.new(Rails.root.join("log", "aoide.log")).tap do |log|
      log.formatter = proc { |severity, time, _progname, msg|
        "[#{time.strftime("%H:%M:%S.%L")}] #{severity}  #{msg}\n"
      }
    end
  end
  private_class_method :build_logger
end
