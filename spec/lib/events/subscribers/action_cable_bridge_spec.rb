# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::ActionCableBridge do
  subject(:bridge) { described_class.instance }

  describe "#emit" do
    it "broadcasts user_message events to the session stream" do
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "hello", session_id: 42)))
      }.to have_broadcasted_to("session_42")
        .with(a_hash_including(type: "user_message", content: "hello", session_id: 42))
    end

    it "broadcasts agent_message events to the session stream" do
      expect {
        bridge.emit(event_hash(Events::AgentMessage.new(content: "hi there", session_id: 7)))
      }.to have_broadcasted_to("session_7")
        .with(a_hash_including(type: "agent_message", content: "hi there"))
    end

    it "broadcasts system_message events" do
      expect {
        bridge.emit(event_hash(Events::SystemMessage.new(content: "retrying...", session_id: 1)))
      }.to have_broadcasted_to("session_1")
        .with(a_hash_including(type: "system_message", content: "retrying..."))
    end

    it "broadcasts tool_call events with tool metadata" do
      expect {
        bridge.emit(event_hash(Events::ToolCall.new(
          content: "running bash", tool_name: "bash",
          tool_input: {cmd: "ls"}, tool_use_id: "toolu_abc",
          session_id: 5
        )))
      }.to have_broadcasted_to("session_5")
        .with(a_hash_including(
          type: "tool_call",
          tool_name: "bash",
          tool_input: {cmd: "ls"},
          tool_use_id: "toolu_abc"
        ))
    end

    it "broadcasts tool_response events with success status" do
      expect {
        bridge.emit(event_hash(Events::ToolResponse.new(
          content: "file.txt", tool_name: "bash", success: true,
          tool_use_id: "toolu_abc", session_id: 5
        )))
      }.to have_broadcasted_to("session_5")
        .with(a_hash_including(
          type: "tool_response",
          tool_name: "bash",
          success: true,
          tool_use_id: "toolu_abc"
        ))
    end

    it "skips events without session_id" do
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "orphan")))
      }.not_to have_broadcasted_to("session_")
    end

    it "skips events with nil payload" do
      expect { bridge.emit({payload: nil}) }.not_to raise_error
    end

    it "skips events with non-hash payload" do
      expect { bridge.emit({payload: "not a hash"}) }.not_to raise_error
    end

    it "isolates broadcasts to the correct session stream" do
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "hello", session_id: 42)))
      }.not_to have_broadcasted_to("session_99")
    end

    it "broadcasts events from different sessions to their respective streams" do
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "first", session_id: 1)))
        bridge.emit(event_hash(Events::UserMessage.new(content: "second", session_id: 2)))
      }.to have_broadcasted_to("session_1").with(a_hash_including(content: "first"))
        .and have_broadcasted_to("session_2").with(a_hash_including(content: "second"))
    end
  end

  describe "integration with EventBus" do
    it "is registered globally at boot and receives events emitted through the Bus" do
      expect {
        Events::Bus.emit(Events::UserMessage.new(content: "via bus", session_id: 10))
      }.to have_broadcasted_to("session_10")
        .with(a_hash_including(type: "user_message", content: "via bus"))
    end
  end

  describe "decoration" do
    it "includes rendered basic output for user messages" do
      Session.create!(id: 42)
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "hello", session_id: 42)))
      }.to have_broadcasted_to("session_42")
        .with(a_hash_including("rendered" => {"basic" => ["You: hello"]}))
    end

    it "includes rendered basic output for agent messages" do
      Session.create!(id: 7)
      expect {
        bridge.emit(event_hash(Events::AgentMessage.new(content: "hi there", session_id: 7)))
      }.to have_broadcasted_to("session_7")
        .with(a_hash_including("rendered" => {"basic" => ["Anima: hi there"]}))
    end

    it "includes nil rendered basic output for tool calls" do
      Session.create!(id: 5)
      expect {
        bridge.emit(event_hash(Events::ToolCall.new(
          content: "calling bash", tool_name: "bash",
          tool_input: {}, session_id: 5
        )))
      }.to have_broadcasted_to("session_5")
        .with(a_hash_including("rendered" => {"basic" => nil}))
    end

    it "includes nil rendered basic output for tool responses" do
      Session.create!(id: 5)
      expect {
        bridge.emit(event_hash(Events::ToolResponse.new(
          content: "output", tool_name: "bash", success: true, session_id: 5
        )))
      }.to have_broadcasted_to("session_5")
        .with(a_hash_including("rendered" => {"basic" => nil}))
    end

    it "decorates in the session's view_mode" do
      Session.create!(id: 42, view_mode: "verbose")
      event = Events::UserMessage.new(content: "hello", session_id: 42)
      expected_time = Time.at(event.timestamp / 1_000_000_000.0).strftime("%H:%M:%S")
      expect {
        bridge.emit(event_hash(event))
      }.to have_broadcasted_to("session_42")
        .with(a_hash_including("rendered" => {"verbose" => ["[#{expected_time}] You: hello"]}))
    end

    it "falls back to basic when session is not found" do
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "hello", session_id: 999)))
      }.to have_broadcasted_to("session_999")
        .with(a_hash_including("rendered" => {"basic" => ["You: hello"]}))
    end
  end

  describe "subscriber interface" do
    it "includes Events::Subscriber" do
      expect(bridge).to be_a(Events::Subscriber)
    end
  end

  # Builds the event hash that Rails.event delivers to subscribers
  def event_hash(event)
    {name: event.event_name, payload: event.to_h, timestamp: event.timestamp}
  end
end
