# frozen_string_literal: true

# Melete — the muse of practice. Watches conversations to activate skills,
# track goals, and name sessions. One of the Three Muses: she prepares the
# stage so Aoide can perform and Mneme can remember.
module Melete
  # Dev-only logger that writes to log/melete.log.
  # In non-development environments returns a null logger so
  # call sites don't need conditionals.
  #
  # @return [Logger]
  def self.logger
    @logger ||= build_logger
  end

  def self.build_logger
    return Logger.new(File::NULL) unless Rails.env.development?

    Logger.new(Rails.root.join("log", "melete.log")).tap do |log|
      log.formatter = proc { |severity, time, _progname, msg|
        "[#{time.strftime("%H:%M:%S.%L")}] #{severity}  #{msg}\n"
      }
    end
  end
  private_class_method :build_logger
end
