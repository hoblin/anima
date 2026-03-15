# frozen_string_literal: true

module AnalyticalBrain
  # Dev-only logger that writes to log/analytical_brain.log.
  # In non-development environments returns a null logger so
  # call sites don't need conditionals.
  #
  # @return [Logger]
  def self.logger
    @logger ||= build_logger
  end

  def self.build_logger
    return Logger.new(File.open(File::NULL, "w")) unless Rails.env.development?

    Logger.new(Rails.root.join("log", "analytical_brain.log")).tap do |log|
      log.formatter = proc { |severity, time, _progname, msg|
        "[#{time.strftime("%H:%M:%S.%L")}] #{severity}  #{msg}\n"
      }
    end
  end
  private_class_method :build_logger
end
