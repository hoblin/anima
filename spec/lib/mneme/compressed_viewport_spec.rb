# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::CompressedViewport do
  let(:session) { Session.create! }

  # Helper to create events with predetermined token counts for deterministic tests.
  def create_message(type:, content: "msg", token_count: 100, tool_name: nil, tool_input: nil, timestamp: nil)
    payload = case type
    when "tool_call"
      {"content" => "Calling #{tool_name}", "tool_name" => tool_name,
       "tool_input" => tool_input || {}, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    when "tool_response"
      {"content" => content, "tool_name" => tool_name, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    else
      {"content" => content}
    end

    session.messages.create!(
      message_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: timestamp || Time.current.to_ns,
      token_count: token_count
    )
  end

  describe "#render" do
    it "returns empty string when session has no events" do
      viewport = described_class.new(session, token_budget: 10_000)
      expect(viewport.render).to eq("")
    end

    it "includes zone delimiters" do
      create_message(type: "user_message", content: "Hello", token_count: 100)
      create_message(type: "agent_message", content: "Hi there", token_count: 100)
      create_message(type: "user_message", content: "How are you?", token_count: 100)

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("EVICTION ZONE")
      expect(result).to include("MIDDLE ZONE")
      expect(result).to include("RECENT ZONE")
    end

    it "renders conversation events with event ID prefix" do
      event = create_message(type: "user_message", content: "Hello world")

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("message #{event.id} User: Hello world")
    end

    it "renders agent messages with Assistant role" do
      event = create_message(type: "agent_message", content: "I can help")

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("message #{event.id} Assistant: I can help")
    end

    it "renders system messages with System role" do
      event = create_message(type: "system_message", content: "Session started")

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("message #{event.id} System: Session started")
    end

    it "compresses tool calls to aggregate counters" do
      create_message(type: "user_message", content: "Run some commands", token_count: 100)
      create_message(type: "tool_call", tool_name: "bash", token_count: 50)
      create_message(type: "tool_response", tool_name: "bash", token_count: 50)
      create_message(type: "tool_call", tool_name: "read_file", token_count: 50)
      create_message(type: "tool_response", tool_name: "read_file", token_count: 50)
      create_message(type: "agent_message", content: "Done", token_count: 100)

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("[2 tools called]")
      expect(result).not_to include("bash")
      expect(result).not_to include("read_file")
    end

    it "uses singular 'tool' for single tool call" do
      create_message(type: "user_message", content: "Run a command", token_count: 100)
      create_message(type: "tool_call", tool_name: "bash", token_count: 50)
      create_message(type: "tool_response", tool_name: "bash", token_count: 50)
      create_message(type: "agent_message", content: "Done", token_count: 100)

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("[1 tool called]")
    end

    it "renders think events as full text (not compressed)" do
      create_message(type: "user_message", content: "Fix the bug", token_count: 100)
      think = create_message(
        type: "tool_call",
        tool_name: "think",
        tool_input: {"thoughts" => "The root cause is a nil check", "visibility" => "inner"},
        token_count: 50
      )
      create_message(type: "tool_response", tool_name: "think", token_count: 10)
      create_message(type: "agent_message", content: "Fixed it", token_count: 100)

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      expect(result).to include("message #{think.id} Think: The root cause is a nil check")
      expect(result).not_to include("[1 tool called]")
    end

    it "splits events into three zones by token count" do
      # Create 9 events, each 100 tokens = 900 total. Zones are ~300 each.
      9.times.map do |i|
        type = i.even? ? "user_message" : "agent_message"
        create_message(type: type, content: "message #{i}", token_count: 100)
      end

      viewport = described_class.new(session, token_budget: 10_000)
      result = viewport.render

      # First 3 events (300 tokens) should be in eviction zone
      eviction_section = result.split("MIDDLE ZONE").first
      expect(eviction_section).to include("message 0")
      expect(eviction_section).to include("message 2")

      # Last 3 events should be in recent zone
      recent_section = result.split("RECENT ZONE").last
      expect(recent_section).to include("message 6")
      expect(recent_section).to include("message 8")
    end
  end

  describe "from_message_id filtering" do
    it "starts from the specified event ID" do
      create_message(type: "user_message", content: "old message", token_count: 100)
      new_event = create_message(type: "user_message", content: "new message", token_count: 100)

      viewport = described_class.new(session, token_budget: 10_000, from_message_id: new_event.id)
      result = viewport.render

      expect(result).not_to include("old message")
      expect(result).to include("new message")
    end
  end

  describe "token budget" do
    it "respects the token budget, selecting oldest messages first" do
      10.times do |i|
        create_message(type: "user_message", content: "message #{i}", token_count: 1000)
      end

      # Budget for 3 events (3000 tokens) — walks oldest-first from boundary
      viewport = described_class.new(session, token_budget: 3000)
      result = viewport.render

      # Should include oldest events (eviction zone) — not newest
      expect(result).to include("message 0")
      expect(result).to include("message 1")
      expect(result).to include("message 2")
      expect(result).not_to include("message 9")
    end

    it "selects oldest messages from boundary, not newest (regression: #422)" do
      # Simulate a long session: 10 messages at 1000 tokens each.
      # Mneme viewport budget = 3000 (fits 3 messages).
      # Boundary at the first message.
      messages = 10.times.map do |i|
        create_message(type: "user_message", content: "message #{i}", token_count: 1000)
      end

      viewport = described_class.new(
        session,
        token_budget: 3000,
        from_message_id: messages.first.id
      )

      # Should select the 3 oldest messages from boundary, not the 3 newest
      selected_ids = viewport.messages.map(&:id)
      expect(selected_ids).to eq(messages[0..2].map(&:id))
      expect(selected_ids).not_to include(messages.last.id)
    end
  end

  describe "#events" do
    it "returns the raw events selected for the viewport" do
      create_message(type: "user_message", content: "Hello", token_count: 100)
      create_message(type: "agent_message", content: "Hi", token_count: 100)

      viewport = described_class.new(session, token_budget: 10_000)
      expect(viewport.messages.size).to eq(2)
    end

    it "does not include pending messages (they live in a separate table)" do
      create_message(type: "user_message", content: "delivered", token_count: 100)
      session.pending_messages.create!(content: "waiting")

      viewport = described_class.new(session, token_budget: 10_000)
      expect(viewport.messages.size).to eq(1)
    end
  end
end
