# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::StartProcessing do
  it "serialises type, session_id, and pending_message_id" do
    event = described_class.new(session_id: 7, pending_message_id: 42)
    expect(event.to_h).to eq(type: "session.start_processing", session_id: 7, pending_message_id: 42)
  end

  it "defaults pending_message_id to nil — emitted at the end of Melete enrichment" do
    expect(described_class.new(session_id: 7).to_h).to eq(
      type: "session.start_processing", session_id: 7, pending_message_id: nil
    )
  end
end
