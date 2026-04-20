# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::SubagentEvicted do
  describe "#to_h" do
    it "serializes as a flat hash with session_id and child_id" do
      event = described_class.new(session_id: 7, child_id: 42)

      expect(event.to_h).to eq(type: "subagent.evicted", session_id: 7, child_id: 42)
    end
  end

  describe "#event_name" do
    it "prefixes the type with the Events::Bus namespace" do
      event = described_class.new(session_id: 1, child_id: 2)

      expect(event.event_name).to eq("anima.subagent.evicted")
    end
  end
end
