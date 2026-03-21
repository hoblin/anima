# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::BounceBack do
  describe "#type" do
    it "returns bounce_back" do
      event = described_class.new(content: "hello", error: "Auth failed", session_id: 1)
      expect(event.type).to eq("bounce_back")
    end
  end

  describe "#to_h" do
    it "includes error and event_id in the serialized hash" do
      event = described_class.new(content: "hello", error: "Auth failed", session_id: 1, event_id: 42)
      hash = event.to_h

      expect(hash[:type]).to eq("bounce_back")
      expect(hash[:content]).to eq("hello")
      expect(hash[:error]).to eq("Auth failed")
      expect(hash[:event_id]).to eq(42)
      expect(hash[:session_id]).to eq(1)
    end

    it "allows nil event_id" do
      event = described_class.new(content: "hello", error: "err", session_id: 1)
      expect(event.to_h[:event_id]).to be_nil
    end
  end

  describe "#event_name" do
    it "uses the anima namespace" do
      event = described_class.new(content: "hello", error: "err", session_id: 1)
      expect(event.event_name).to eq("anima.bounce_back")
    end
  end
end
