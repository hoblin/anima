# frozen_string_literal: true

# Mneme — the memory department. Watches for viewport eviction and creates
# summaries before context is lost. Named after the Greek Titaness of memory.
#
# Mneme is the third event bus department alongside Nous (main agent) and
# the Analytical Brain. It operates as a phantom LLM loop: observes the
# main session, creates snapshots, but leaves no trace of its own reasoning.
module Mneme
  # Dev-only logger that writes to log/mneme.log.
  # In non-development environments returns a null logger so
  # call sites don't need conditionals.
  #
  # @return [Logger]
  def self.logger
    @logger ||= build_logger
  end

  def self.build_logger
    return Logger.new(File::NULL) unless Rails.env.development?

    Logger.new(Rails.root.join("log", "mneme.log")).tap do |log|
      log.formatter = proc { |severity, time, _progname, msg|
        "[#{time.strftime("%H:%M:%S.%L")}] #{severity}  #{msg}\n"
      }
    end
  end
  private_class_method :build_logger
end
