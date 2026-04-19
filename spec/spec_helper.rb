# frozen_string_literal: true

require "anima"
require "tui/settings"

module EnvHelpers
  def with_env(vars)
    originals = vars.to_h { |k, _| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| ENV[k] = v }
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include EnvHelpers

  # TUI specs consume TUI::Settings values; loading them from TEMPLATE up
  # front avoids a ~256ms TomlRB.load_file parse per example.
  config.before(:suite) { TUI::Settings.load_defaults! }

  # Silence $stdout/$stderr for examples tagged :silence_output. The
  # formatter holds its reference to the real $stdout from config-load
  # time, so failures/progress/summary are unaffected. Inside a tagged
  # example, assert on captured output via $stdout.string / $stderr.string.
  #
  # The real streams are stashed under distinctive globals so teardown is
  # greppable and a rogue leak (e.g. if `ensure` is skipped via exit!) is
  # easy to trace instead of hiding behind generic names.
  config.around(:each, :silence_output) do |example|
    $anima_silence_original_stdout = $stdout
    $anima_silence_original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    example.run
  ensure
    $stdout = $anima_silence_original_stdout if $anima_silence_original_stdout
    $stderr = $anima_silence_original_stderr if $anima_silence_original_stderr
    $anima_silence_original_stdout = nil
    $anima_silence_original_stderr = nil
  end
end
