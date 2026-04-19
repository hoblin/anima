# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::UserMessage do
  it "serialises type, content, session_id, and a timestamp" do
    event = described_class.new(content: "Hello Claude", session_id: "sess-1")
    hash = event.to_h

    expect(hash).to include(type: "user_message", content: "Hello Claude", session_id: "sess-1")
    expect(hash[:timestamp]).to be_a(Integer)
  end
end
