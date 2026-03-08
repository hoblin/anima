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
