# frozen_string_literal: true

# Mneme — the muse of memory. Watches for viewport eviction and creates
# summaries before context is lost. One of the Three Muses: she remembers
# while Melete prepares and Aoide performs.
#
# Operates as a phantom LLM loop: observes the main session, creates
# snapshots, but leaves no trace of her own reasoning.
module Mneme
  # Estimated token overhead for a synthetic +tool_use+/+tool_result+
  # pair — the wrapper JSON that phantom promotions emit around their
  # content (tool name, input hash, ids, framing). Added to the content's
  # token estimate when sizing phantom pairs in the viewport.
  TOOL_PAIR_OVERHEAD_TOKENS = 50

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
