# frozen_string_literal: true

require "rails_helper"

RSpec.describe EventDecorator do
  describe ".for" do
    it "returns UserMessageDecorator for user_message" do
      decorator = described_class.for({"type" => "user_message", "content" => "hi"})
      expect(decorator).to be_a(UserMessageDecorator)
    end

    it "returns AgentMessageDecorator for agent_message" do
      decorator = described_class.for({"type" => "agent_message", "content" => "hello"})
      expect(decorator).to be_a(AgentMessageDecorator)
    end

    it "returns ToolCallDecorator for tool_call" do
      decorator = described_class.for({"type" => "tool_call", "content" => "bash"})
      expect(decorator).to be_a(ToolCallDecorator)
    end

    it "returns ToolResponseDecorator for tool_response" do
      decorator = described_class.for({"type" => "tool_response", "content" => "ok"})
      expect(decorator).to be_a(ToolResponseDecorator)
    end

    it "returns SystemMessageDecorator for system_message" do
      decorator = described_class.for({"type" => "system_message", "content" => "retry"})
      expect(decorator).to be_a(SystemMessageDecorator)
    end

    it "raises ArgumentError for unknown event types" do
      expect {
        described_class.for({"type" => "unknown", "content" => "data"})
      }.to raise_error(ArgumentError, /Unknown event type: "unknown"/)
    end

    it "raises ArgumentError for nil event type" do
      expect {
        described_class.for({"content" => "data"})
      }.to raise_error(ArgumentError, /Unknown event type: nil/)
    end

    it "passes context to the decorator" do
      decorator = described_class.for(
        {"type" => "user_message", "content" => "hi"},
        context: {mode: :verbose}
      )
      expect(decorator.context).to eq({mode: :verbose})
    end
  end

  describe "#render_basic" do
    it "raises NotImplementedError on base class" do
      decorator = described_class.new({"type" => "user_message", "content" => "hi"})
      expect { decorator.render_basic }.to raise_error(NotImplementedError)
    end
  end

  describe "#render_verbose" do
    it "raises NotImplementedError (not yet implemented)" do
      decorator = UserMessageDecorator.new({"type" => "user_message", "content" => "hi"})
      expect { decorator.render_verbose }.to raise_error(NotImplementedError, /not yet implemented/)
    end
  end

  describe "#render_debug" do
    it "raises NotImplementedError (not yet implemented)" do
      decorator = UserMessageDecorator.new({"type" => "user_message", "content" => "hi"})
      expect { decorator.render_debug }.to raise_error(NotImplementedError, /not yet implemented/)
    end
  end

  describe "#label" do
    it "returns nil on base class" do
      decorator = described_class.new({"type" => "user_message", "content" => "hi"})
      expect(decorator.label).to be_nil
    end
  end

  describe "#role" do
    it "returns nil on base class" do
      decorator = described_class.new({"type" => "user_message", "content" => "hi"})
      expect(decorator.role).to be_nil
    end
  end
end
