# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::ToolCall do
  subject(:event) do
    described_class.new(
      content: "Running bash command",
      tool_name: "bash",
      tool_input: {command: "ls -la"},
      session_id: "sess-1"
    )
  end

  it "has type tool_call" do
    expect(event.type).to eq("tool_call")
  end

  it "stores tool_name" do
    expect(event.tool_name).to eq("bash")
  end

  it "stores tool_input" do
    expect(event.tool_input).to eq({command: "ls -la"})
  end

  it "defaults tool_input to empty hash" do
    event = described_class.new(content: "test", tool_name: "bash")
    expect(event.tool_input).to eq({})
  end

  describe "#to_h" do
    it "includes tool-specific fields" do
      hash = event.to_h
      expect(hash).to include(
        type: "tool_call",
        content: "Running bash command",
        tool_name: "bash",
        tool_input: {command: "ls -la"}
      )
    end
  end
end
