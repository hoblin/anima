# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::AgentMessage do
  subject(:event) { described_class.new(content: "Hello human", session_id: "sess-1") }

  it "has type agent_message" do
    expect(event.type).to eq("agent_message")
  end

  it "has correct event_name" do
    expect(event.event_name).to eq("anima.agent_message")
  end

  describe "#to_h" do
    it "includes type, content, session_id, and timestamp" do
      hash = event.to_h
      expect(hash).to include(
        type: "agent_message",
        content: "Hello human",
        session_id: "sess-1"
      )
    end
  end
end
