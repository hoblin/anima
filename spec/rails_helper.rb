# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rspec/rails"
require "webmock/rspec"

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

# Ensure test database schema is current (critical for CI where db/schema.rb is gitignored).
ActiveRecord::Tasks::DatabaseTasks.prepare_all

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include ActiveJob::TestHelper

  # Stub Settings for all specs so tests never touch the real config file.
  config.before do
    allow(Anima::Settings).to receive(:config).and_return(
      "llm" => {
        "model" => "claude-sonnet-4-20250514",
        "fast_model" => "claude-haiku-4-5",
        "max_tokens" => 8192,
        "max_tool_rounds" => 500,
        "token_budget" => 190_000
      },
      "timeouts" => {"api" => 300, "command" => 30, "mcp_response" => 60, "web_request" => 10, "tool" => 180},
      "shell" => {"max_output_bytes" => 100_000},
      "tools" => {"max_file_size" => 10_485_760, "max_read_lines" => 2_000, "max_read_bytes" => 50_000, "max_web_response_bytes" => 100_000, "min_web_content_chars" => 100},
      "paths" => {"soul" => Rails.root.join("templates/soul.md").to_s},
      "session" => {"default_view_mode" => "basic", "name_generation_interval" => 30},
      "analytical_brain" => {"max_tokens" => 4096, "blocking_on_user_message" => true, "blocking_on_agent_message" => false, "event_window" => 20},
      "environment" => {"project_files" => ["CLAUDE.md", "AGENTS.md", "README.md", "CONTRIBUTING.md"], "project_files_max_depth" => 3},
      "mneme" => {"max_tokens" => 2048, "viewport_fraction" => 0.33, "l1_budget_fraction" => 0.15, "l2_budget_fraction" => 0.05, "l2_snapshot_threshold" => 5, "pinned_budget_fraction" => 0.05},
      "recall" => {"max_results" => 5, "budget_fraction" => 0.05, "max_snippet_tokens" => 512, "recency_decay" => 0.3}
    )
  end
end
