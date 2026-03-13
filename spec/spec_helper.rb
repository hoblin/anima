# frozen_string_literal: true

require "anima"

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

  # E2E tests require a running brain and tmux; run explicitly with: rspec --tag e2e
  config.filter_run_excluding e2e: true

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include EnvHelpers
end
