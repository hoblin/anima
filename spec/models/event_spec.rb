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

    it "requires tool_use_id for tool_call events" do
      event = Event.new(session: session, event_type: "tool_call", payload: {content: "run"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:tool_use_id]).to include("can't be blank")
    end

    it "requires tool_use_id for tool_response events" do
      event = Event.new(session: session, event_type: "tool_response", payload: {content: "ok"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:tool_use_id]).to include("can't be blank")
    end

    it "does not require tool_use_id for non-tool events" do
      %w[system_message user_message agent_message].each do |type|
        event = Event.new(session: session, event_type: type, payload: {content: "hi"}, timestamp: 1)
        expect(event).to be_valid, "expected #{type} to be valid without tool_use_id"
      end
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
      session.events.create!(event_type: "tool_call", payload: {content: "run", tool_name: "bash", tool_input: {}}, tool_use_id: "toolu_test1", timestamp: 4)

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
      event = session.events.create!(event_type: "tool_call", payload: {content: "run"}, tool_use_id: "toolu_test1", timestamp: 1)
      expect { event.api_role }.to raise_error(KeyError)
    end
  end

  describe ".context_events" do
    it "returns user, agent, tool_call, and tool_response events" do
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {content: "hello"}, timestamp: 2)
      session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 3)
      session.events.create!(event_type: "tool_call", payload: {content: "run", tool_name: "web_get"}, tool_use_id: "toolu_test1", timestamp: 4)
      session.events.create!(event_type: "tool_response", payload: {content: "ok", tool_name: "web_get"}, tool_use_id: "toolu_test1", timestamp: 5)

      expect(Event.context_events.pluck(:event_type)).to match_array(
        %w[system_message user_message agent_message tool_call tool_response]
      )
    end

    it "includes system_message events" do
      session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 1)

      expect(Event.context_events.pluck(:event_type)).to include("system_message")
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

    it "returns true for system_message" do
      expect(Event.new(event_type: "system_message")).to be_context_event
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
        tool_use_id: "toolu_test1",
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

  describe ".excluding_spawn_events" do
    it "excludes spawn_subagent tool_call events" do
      session.events.create!(event_type: "tool_call", payload: {"tool_name" => "spawn_subagent", "content" => "spawning"}, tool_use_id: "toolu_spawn1", timestamp: 1)
      kept = session.events.create!(event_type: "tool_call", payload: {"tool_name" => "bash", "content" => "running"}, tool_use_id: "toolu_bash1", timestamp: 2)

      expect(session.events.excluding_spawn_events).to eq([kept])
    end

    it "excludes spawn_specialist tool_call events" do
      session.events.create!(event_type: "tool_call", payload: {"tool_name" => "spawn_specialist", "content" => "spawning"}, tool_use_id: "toolu_spawn1", timestamp: 1)
      kept = session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: 2)

      expect(session.events.excluding_spawn_events).to eq([kept])
    end

    it "excludes spawn tool_response events" do
      session.events.create!(event_type: "tool_response", payload: {"tool_name" => "spawn_subagent", "content" => "spawned"}, tool_use_id: "toolu_spawn1", timestamp: 1)
      session.events.create!(event_type: "tool_response", payload: {"tool_name" => "spawn_specialist", "content" => "spawned"}, tool_use_id: "toolu_spawn2", timestamp: 2)
      kept = session.events.create!(event_type: "tool_response", payload: {"tool_name" => "bash", "content" => "output"}, tool_use_id: "toolu_bash1", timestamp: 3)

      expect(session.events.excluding_spawn_events).to eq([kept])
    end

    it "preserves non-tool events" do
      user_msg = session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: 1)
      agent_msg = session.events.create!(event_type: "agent_message", payload: {"content" => "hi"}, timestamp: 2)
      sys_msg = session.events.create!(event_type: "system_message", payload: {"content" => "boot"}, timestamp: 3)
      session.events.create!(event_type: "tool_call", payload: {"tool_name" => "spawn_specialist", "content" => "spawning"}, tool_use_id: "toolu_spawn1", timestamp: 4)

      expect(session.events.excluding_spawn_events).to eq([user_msg, agent_msg, sys_msg])
    end

    it "preserves non-spawn tool events" do
      bash_call = session.events.create!(event_type: "tool_call", payload: {"tool_name" => "bash", "content" => "running"}, tool_use_id: "toolu_bash1", timestamp: 1)
      bash_response = session.events.create!(event_type: "tool_response", payload: {"tool_name" => "bash", "content" => "output"}, tool_use_id: "toolu_bash1", timestamp: 2)
      read_call = session.events.create!(event_type: "tool_call", payload: {"tool_name" => "read", "content" => "reading"}, tool_use_id: "toolu_read1", timestamp: 3)

      expect(session.events.excluding_spawn_events).to eq([bash_call, bash_response, read_call])
    end
  end

  describe "#conversation_or_think?" do
    it "returns true for user_message" do
      expect(Event.new(event_type: "user_message", payload: {})).to be_conversation_or_think
    end

    it "returns true for agent_message" do
      expect(Event.new(event_type: "agent_message", payload: {})).to be_conversation_or_think
    end

    it "returns true for system_message" do
      expect(Event.new(event_type: "system_message", payload: {})).to be_conversation_or_think
    end

    it "returns true for think tool_call" do
      event = Event.new(event_type: "tool_call", payload: {"tool_name" => "think"})
      expect(event).to be_conversation_or_think
    end

    it "returns false for non-think tool_call" do
      event = Event.new(event_type: "tool_call", payload: {"tool_name" => "bash"})
      expect(event).not_to be_conversation_or_think
    end

    it "returns false for tool_response" do
      event = Event.new(event_type: "tool_response", payload: {"tool_name" => "bash"})
      expect(event).not_to be_conversation_or_think
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
