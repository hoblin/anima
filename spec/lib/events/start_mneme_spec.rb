# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::StartMneme do
  it "serialises type, session_id, and pending_message_id" do
    event = described_class.new(session_id: 7, pending_message_id: 42)
    expect(event.to_h).to eq(type: "session.start_mneme", session_id: 7, pending_message_id: 42)
  end

  it "requires pending_message_id — Mneme always has a triggering message" do
    expect { described_class.new(session_id: 7) }.to raise_error(ArgumentError)
  end
end
