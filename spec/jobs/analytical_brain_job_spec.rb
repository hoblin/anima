# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrainJob do
  let(:session) { Session.create! }

  describe "retry configuration" do
    it "retries on TransientError" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::TransientError" }
      )
    end

    it "discards on AuthenticationError" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::AuthenticationError" }
      )
    end

    it "discards on RecordNotFound" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "ActiveRecord::RecordNotFound" }
      )
    end
  end

  describe "#perform" do
    it "runs the analytical brain for the given session", :vcr do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      expect { described_class.perform_now(session.id) }.not_to raise_error
    end

    it "renames the session when the LLM calls rename_session", :vcr do
      session.events.create!(event_type: "user_message", payload: {"content" => "Help me set up a new Rails 8 project with PostgreSQL and Hotwire for a blog platform"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "I'll help you set up a Rails 8 blog with PostgreSQL and Hotwire. Let's start with `rails new blog --database=postgresql`..."}, timestamp: 2)

      described_class.perform_now(session.id)

      expect(session.reload.name).to be_present
    end

    it "does not persist analytical brain events to the database", :vcr do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      expect { described_class.perform_now(session.id) }
        .not_to change(Event, :count)
    end

    it "discards the job if the session no longer exists" do
      expect { described_class.perform_now(999_999) }.not_to raise_error
    end

    it "does nothing for sessions with no events", :vcr do
      expect { described_class.perform_now(session.id) }.not_to raise_error
    end
  end
end
