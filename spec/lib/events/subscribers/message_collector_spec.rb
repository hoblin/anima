# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::MessageCollector do
  subject(:collector) { described_class.new }

  after { Events::Bus.unsubscribe(collector) }

  describe "#emit" do
    it "collects user_message events as user role" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::UserMessage.new(content: "hello"))

      expect(collector.messages).to eq([{role: "user", content: "hello"}])
    end

    it "collects agent_message events as assistant role" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::AgentMessage.new(content: "hi there"))

      expect(collector.messages).to eq([{role: "assistant", content: "hi there"}])
    end

    it "ignores system_message events" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::SystemMessage.new(content: "session started"))

      expect(collector.messages).to be_empty
    end

    it "ignores tool_call events" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::ToolCall.new(content: "running", tool_name: "bash"))

      expect(collector.messages).to be_empty
    end

    it "ignores tool_response events" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::ToolResponse.new(content: "output", tool_name: "bash"))

      expect(collector.messages).to be_empty
    end

    it "preserves message order across types" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::UserMessage.new(content: "first"))
      Events::Bus.emit(Events::AgentMessage.new(content: "second"))
      Events::Bus.emit(Events::UserMessage.new(content: "third"))

      expect(collector.messages).to eq([
        {role: "user", content: "first"},
        {role: "assistant", content: "second"},
        {role: "user", content: "third"}
      ])
    end

    it "ignores events with nil content" do
      Events::Bus.subscribe(collector)

      event = {payload: {type: "user_message", content: nil}}
      collector.emit(event)

      expect(collector.messages).to be_empty
    end

    it "collects events after clear" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::UserMessage.new(content: "before"))

      collector.clear
      Events::Bus.emit(Events::UserMessage.new(content: "after"))

      expect(collector.messages).to eq([{role: "user", content: "after"}])
    end
  end

  describe "DISPLAYABLE_TYPES and ROLE_MAP consistency" do
    it "has a ROLE_MAP entry for every DISPLAYABLE_TYPE" do
      described_class::DISPLAYABLE_TYPES.each do |type|
        expect(described_class::ROLE_MAP).to have_key(type),
          "ROLE_MAP missing key for displayable type '#{type}'"
      end
    end
  end

  describe "#messages" do
    it "returns a copy that does not affect internal state" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::UserMessage.new(content: "hello"))

      returned = collector.messages
      returned.clear

      expect(collector.messages.length).to eq(1)
    end
  end

  describe "#clear" do
    it "empties the messages array" do
      Events::Bus.subscribe(collector)
      Events::Bus.emit(Events::UserMessage.new(content: "hello"))

      collector.clear
      expect(collector.messages).to be_empty
    end
  end
end
