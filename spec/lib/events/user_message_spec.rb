# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::UserMessage do
  subject(:event) { described_class.new(content: "Hello Claude", session_id: "sess-1") }

  it "has type user_message" do
    expect(event.type).to eq("user_message")
  end

  it "has correct event_name" do
    expect(event.event_name).to eq("anima.user_message")
  end

  describe "#to_h" do
    it "includes type, content, session_id, and timestamp" do
      hash = event.to_h
      expect(hash).to include(
        type: "user_message",
        content: "Hello Claude",
        session_id: "sess-1"
      )
      expect(hash[:timestamp]).to be_a(Integer)
    end

    it "excludes status when nil" do
      expect(event.to_h).not_to have_key(:status)
    end

    it "includes status when pending" do
      pending_event = described_class.new(content: "queued", session_id: "s1", status: "pending")
      expect(pending_event.to_h[:status]).to eq("pending")
    end
  end

  describe "#status" do
    it "defaults to nil" do
      expect(event.status).to be_nil
    end

    it "accepts pending status" do
      pending_event = described_class.new(content: "queued", status: "pending")
      expect(pending_event.status).to eq("pending")
    end
  end
end
