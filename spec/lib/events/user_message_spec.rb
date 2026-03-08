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
  end
end
