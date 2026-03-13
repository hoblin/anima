# frozen_string_literal: true

require "rails_helper"

RSpec.describe Event do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires event_type" do
      event = Event.new(session: session, payload: {content: "hi"}, timestamp: 1)
      event.event_type = nil
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("can't be blank")
    end

    it "rejects invalid event_type" do
      event = Event.new(session: session, event_type: "invalid", payload: {content: "hi"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("is not included in the list")
    end

    it "requires payload" do
      event = Event.new(session: session, event_type: "user_message", timestamp: 1)
      event.payload = nil
      expect(event).not_to be_valid
      expect(event.errors[:payload]).to include("can't be blank")
    end

    it "requires timestamp" do
      event = Event.new(session: session, event_type: "user_message", payload: {content: "hi"})
      event.timestamp = nil
      expect(event).not_to be_valid
      expect(event.errors[:timestamp]).to include("can't be blank")
    end

    it "requires session" do
      event = Event.new(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event).not_to be_valid
    end

    it "is valid with all required attributes" do
      event = Event.new(session: session, event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event).to be_valid
    end
  end

  describe ".llm_messages" do
    it "returns only user_message and agent_message events" do
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {content: "hello"}, timestamp: 2)
      session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 3)
      session.events.create!(event_type: "tool_call", payload: {content: "run", tool_name: "bash", tool_input: {}}, timestamp: 4)

      expect(Event.llm_messages.pluck(:event_type)).to match_array(%w[user_message agent_message])
    end
  end

  describe "associations" do
    it "belongs to a session" do
      event = session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.session).to eq(session)
    end
  end

  describe "token_count" do
    it "defaults to 0" do
      event = session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.token_count).to eq(0)
    end
  end

  describe "#api_role" do
    it "maps user_message to user" do
      event = session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.api_role).to eq("user")
    end

    it "maps agent_message to assistant" do
      event = session.events.create!(event_type: "agent_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.api_role).to eq("assistant")
    end

    it "raises KeyError for non-LLM event types" do
      event = session.events.create!(event_type: "tool_call", payload: {content: "run"}, timestamp: 1)
      expect { event.api_role }.to raise_error(KeyError)
    end
  end

  describe ".context_events" do
    it "returns user, agent, tool_call, and tool_response events" do
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {content: "hello"}, timestamp: 2)
      session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 3)
      session.events.create!(event_type: "tool_call", payload: {content: "run", tool_name: "web_get"}, timestamp: 4)
      session.events.create!(event_type: "tool_response", payload: {content: "ok", tool_name: "web_get"}, timestamp: 5)

      expect(Event.context_events.pluck(:event_type)).to match_array(
        %w[user_message agent_message tool_call tool_response]
      )
    end

    it "excludes system_message events" do
      session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 1)

      expect(Event.context_events).to be_empty
    end
  end

  describe "#llm_message?" do
    it "returns true for user_message" do
      event = Event.new(event_type: "user_message")
      expect(event).to be_llm_message
    end

    it "returns true for agent_message" do
      event = Event.new(event_type: "agent_message")
      expect(event).to be_llm_message
    end

    it "returns false for system_message" do
      event = Event.new(event_type: "system_message")
      expect(event).not_to be_llm_message
    end
  end

  describe "#context_event?" do
    it "returns true for user_message" do
      expect(Event.new(event_type: "user_message")).to be_context_event
    end

    it "returns true for tool_call" do
      expect(Event.new(event_type: "tool_call")).to be_context_event
    end

    it "returns true for tool_response" do
      expect(Event.new(event_type: "tool_response")).to be_context_event
    end

    it "returns false for system_message" do
      expect(Event.new(event_type: "system_message")).not_to be_context_event
    end
  end

  describe "#pending?" do
    it "returns true when status is pending" do
      event = Event.new(event_type: "user_message", status: "pending")
      expect(event).to be_pending
    end

    it "returns false when status is nil" do
      event = Event.new(event_type: "user_message", status: nil)
      expect(event).not_to be_pending
    end
  end

  describe ".pending" do
    it "returns only pending events" do
      session.events.create!(event_type: "user_message", payload: {content: "delivered"}, timestamp: 1)
      pending = session.events.create!(event_type: "user_message", payload: {content: "queued"}, timestamp: 2, status: "pending")

      expect(Event.pending).to eq([pending])
    end
  end

  describe ".deliverable" do
    it "excludes pending events" do
      delivered = session.events.create!(event_type: "user_message", payload: {content: "delivered"}, timestamp: 1)
      session.events.create!(event_type: "user_message", payload: {content: "queued"}, timestamp: 2, status: "pending")

      expect(Event.deliverable).to eq([delivered])
    end
  end

  describe "#estimate_tokens" do
    it "estimates tokens from content for message events" do
      event = session.events.create!(
        event_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1
      )

      # "hello world" = 11 bytes, 11/4 = 2.75, ceil = 3
      expect(event.estimate_tokens).to eq(3)
    end

    it "estimates tokens from full payload JSON for tool events" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        timestamp: 1
      )
      json_size = event.payload.to_json.bytesize
      expected = (json_size / 4.0).ceil

      expect(event.estimate_tokens).to eq(expected)
    end

    it "returns at least 1 for empty content" do
      event = session.events.create!(
        event_type: "user_message", payload: {"content" => ""}, timestamp: 1
      )

      expect(event.estimate_tokens).to eq(1)
    end

    it "returns at least 1 for nil content" do
      event = session.events.create!(
        event_type: "user_message", payload: {"content" => nil}, timestamp: 1
      )

      expect(event.estimate_tokens).to eq(1)
    end
  end

  describe "after_create callback" do
    it "enqueues CountEventTokensJob for LLM events" do
      expect {
        session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      }.to have_enqueued_job(CountEventTokensJob)
    end

    it "does not enqueue CountEventTokensJob for non-LLM events" do
      expect {
        session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 1)
      }.not_to have_enqueued_job(CountEventTokensJob)
    end
  end
end
