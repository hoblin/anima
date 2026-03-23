# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Search do
  let(:session) { Session.create! }
  let(:other_session) { Session.create! }

  def create_event(session, type:, content: "msg", tool_name: nil)
    payload = if type == "tool_call" && tool_name == "think"
      {"tool_name" => "think", "tool_input" => {"thoughts" => content}, "tool_use_id" => SecureRandom.hex(8)}
    elsif type == "tool_call"
      {"tool_name" => tool_name, "tool_input" => {}, "tool_use_id" => SecureRandom.hex(8)}
    else
      {"content" => content}
    end

    session.events.create!(
      event_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    )
  end

  describe ".query" do
    it "returns empty for blank terms" do
      expect(described_class.query("")).to eq([])
      expect(described_class.query(nil)).to eq([])
    end

    it "finds user messages by keyword" do
      event = create_event(session, type: "user_message", content: "How does authentication work?")
      create_event(session, type: "user_message", content: "Tell me about the weather.")

      results = described_class.query("authentication")

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(event.id)
      expect(results.first.session_id).to eq(session.id)
      expect(results.first.event_type).to eq("human")
    end

    it "finds agent messages by keyword" do
      event = create_event(session, type: "agent_message", content: "The OAuth flow uses PKCE for security.")

      results = described_class.query("OAuth PKCE")

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(event.id)
      expect(results.first.event_type).to eq("anima")
    end

    it "finds think events by keyword" do
      event = create_event(session, type: "tool_call", tool_name: "think",
        content: "The migration strategy needs careful planning.")

      results = described_class.query("migration strategy")

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(event.id)
      expect(results.first.event_type).to eq("thought")
    end

    it "finds system messages by keyword" do
      event = create_event(session, type: "system_message", content: "System context initialized with debug mode.")

      results = described_class.query("debug mode")

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(event.id)
      expect(results.first.event_type).to eq("system")
    end

    it "does not index non-think tool_call events" do
      create_event(session, type: "tool_call", tool_name: "bash")

      results = described_class.query("bash")

      expect(results).to be_empty
    end

    it "searches across sessions by default" do
      e1 = create_event(session, type: "user_message", content: "Deploy the database changes.")
      e2 = create_event(other_session, type: "user_message", content: "Database migration failed.")

      results = described_class.query("database")

      expect(results.map(&:event_id)).to contain_exactly(e1.id, e2.id)
    end

    it "scopes to a specific session when session_id given" do
      create_event(session, type: "user_message", content: "Deploy the database changes.")
      e2 = create_event(other_session, type: "user_message", content: "Database migration failed.")

      results = described_class.query("database", session_id: other_session.id)

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(e2.id)
    end

    it "respects the limit parameter" do
      5.times { |i| create_event(session, type: "user_message", content: "Ruby version #{i} is great.") }

      results = described_class.query("Ruby", limit: 2)

      expect(results.size).to eq(2)
    end

    it "returns results with snippets containing match highlights" do
      create_event(session, type: "user_message", content: "The authentication module needs refactoring.")

      results = described_class.query("authentication")

      expect(results.first.snippet).to include("authentication")
    end

    it "returns results with rank scores" do
      create_event(session, type: "user_message", content: "Authentication is broken.")

      results = described_class.query("authentication")

      expect(results.first.rank).to be_a(Numeric)
    end

    it "sanitizes FTS5 special characters" do
      create_event(session, type: "user_message", content: "Testing the search system.")

      # These should not raise FTS5 syntax errors
      expect { described_class.query("test*") }.not_to raise_error
      expect { described_class.query("test:query") }.not_to raise_error
      expect { described_class.query("test{query}") }.not_to raise_error
    end

    it "handles quoted phrases" do
      create_event(session, type: "user_message", content: "The full text search works well.")

      results = described_class.query('"full text search"')

      expect(results.size).to eq(1)
    end

    # Regression: #289 — common words like "bash" were interpolated as column
    # references instead of string values when bind params were passed as a
    # raw array to select_all.
    it "handles terms that resemble SQL column names" do
      event = create_event(session, type: "user_message", content: "Learn bash scripting basics.")

      results = described_class.query("bash")

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(event.id)
    end

    it "handles terms that resemble SQL column names with session scope" do
      event = create_event(session, type: "user_message", content: "Learn bash scripting basics.")
      create_event(other_session, type: "user_message", content: "More bash tips here.")

      results = described_class.query("bash", session_id: session.id)

      expect(results.size).to eq(1)
      expect(results.first.event_id).to eq(event.id)
    end
  end
end
