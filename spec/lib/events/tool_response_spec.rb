# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::ToolResponse do
  subject(:event) do
    described_class.new(
      content: "file1.rb\nfile2.rb",
      tool_name: "bash",
      success: true,
      tool_use_id: "toolu_abc123",
      session_id: "sess-1"
    )
  end

  it "has type tool_response" do
    expect(event.type).to eq("tool_response")
  end

  it "stores tool_name" do
    expect(event.tool_name).to eq("bash")
  end

  it "stores tool_use_id" do
    expect(event.tool_use_id).to eq("toolu_abc123")
  end

  it "reports success" do
    expect(event).to be_success
  end

  it "reports failure" do
    event = described_class.new(content: "error", tool_name: "bash", success: false)
    expect(event).not_to be_success
  end

  it "defaults success to true" do
    event = described_class.new(content: "ok", tool_name: "bash")
    expect(event).to be_success
  end

  it "defaults tool_use_id to nil" do
    event = described_class.new(content: "ok", tool_name: "bash")
    expect(event.tool_use_id).to be_nil
  end

  describe "#to_h" do
    it "includes tool-specific fields" do
      hash = event.to_h
      expect(hash).to include(
        type: "tool_response",
        tool_name: "bash",
        success: true,
        tool_use_id: "toolu_abc123"
      )
    end
  end
end
