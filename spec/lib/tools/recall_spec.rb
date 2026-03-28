# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Recall do
  let(:session) { Session.create!(name: "Current Session") }
  let(:tool) { described_class.new(session: session) }

  def create_message(sess, type:, content: "msg", tool_name: nil)
    payload = if type == "tool_call"
      name = tool_name || "bash"
      {"tool_name" => name, "tool_input" => ((name == "think") ? {"thoughts" => content} : {"cmd" => "ls"}), "tool_use_id" => SecureRandom.hex(8)}
    elsif type == "tool_response"
      {"content" => content, "tool_use_id" => SecureRandom.hex(8)}
    else
      {"content" => content}
    end

    sess.messages.create!(
      message_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    )
  end

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("recall") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("recall")
      expect(schema[:description]).to include("Search past conversations")
      expect(schema[:input_schema][:required]).to include("query")
    end
  end

  describe "#execute" do
    it "returns error for blank query" do
      result = tool.execute("query" => "  ")

      expect(result).to be_a(Hash)
      expect(result[:error]).to include("cannot be blank")
    end

    it "returns no results message when nothing matches" do
      result = tool.execute("query" => "xyznonexistent")

      expect(result).to be_a(String)
      expect(result).to include("No results found")
    end

    it "finds messages matching the query" do
      create_message(session, type: "user_message", content: "Implementing the authentication flow with OAuth2")

      result = tool.execute("query" => "authentication")

      expect(result).to include("authentication")
      expect(result).to include("Found 1 results")
    end

    it "includes message IDs for drill-down" do
      msg = create_message(session, type: "user_message", content: "Deploying to production server")

      result = tool.execute("query" => "deploying production")

      expect(result).to include("message #{msg.id}")
    end

    it "includes session name in results" do
      named_session = Session.create!(name: "Auth Refactoring")
      create_message(named_session, type: "user_message", content: "Refactoring the auth middleware")

      result = tool.execute("query" => "auth middleware")

      expect(result).to include("Auth Refactoring")
    end

    it "includes message type in results" do
      create_message(session, type: "user_message", content: "The database migration strategy")

      result = tool.execute("query" => "database migration")

      expect(result).to include("human")
    end

    it "searches across all sessions by default" do
      other_session = Session.create!(name: "Other Session")
      create_message(session, type: "user_message", content: "First session content about caching")
      create_message(other_session, type: "user_message", content: "Second session content about caching")

      result = tool.execute("query" => "caching")

      expect(result).to include("Current Session")
      expect(result).to include("Other Session")
    end

    it "restricts to current session when session_only is true" do
      other_session = Session.create!(name: "Other Session")
      create_message(session, type: "user_message", content: "Local session content about routing")
      create_message(other_session, type: "user_message", content: "Other session content about routing")

      result = tool.execute("query" => "routing", "session_only" => true)

      expect(result).to include("Current Session")
      expect(result).not_to include("Other Session")
    end

    it "searches think tool calls" do
      create_message(session, type: "tool_call", tool_name: "think",
        content: "Reasoning about the polymorphic association design")

      result = tool.execute("query" => "polymorphic association")

      expect(result).to include("polymorphic")
      expect(result).to include("thought")
    end

    it "falls back to session ID when session has no name" do
      unnamed_session = Session.create!
      create_message(unnamed_session, type: "user_message", content: "Unnamed session content about testing")

      result = tool.execute("query" => "testing")

      expect(result).to include("Session ##{unnamed_session.id}")
    end

    it "returns multiple ranked results" do
      3.times { |i| create_message(session, type: "user_message", content: "Discussion about webhooks topic #{i}") }

      result = tool.execute("query" => "webhooks")

      expect(result).to include("Found 3 results")
    end
  end
end
