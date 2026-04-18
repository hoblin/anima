# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::StartMneme do
  subject(:event) { described_class.new(session_id: 7, pending_message_id: 42) }

  it "exposes its type constant" do
    expect(described_class::TYPE).to eq("session.start_mneme")
  end

  it "stores session_id" do
    expect(event.session_id).to eq(7)
  end

  it "stores pending_message_id" do
    expect(event.pending_message_id).to eq(42)
  end

  it "namespaces the event_name for the bus" do
    expect(event.event_name).to eq("anima.session.start_mneme")
  end

  describe "#to_h" do
    it "serialises type, session_id, and pending_message_id" do
      expect(event.to_h).to eq(
        type: "session.start_mneme",
        session_id: 7,
        pending_message_id: 42
      )
    end
  end

  it "requires pending_message_id (Mneme always has a triggering message)" do
    expect { described_class.new(session_id: 7) }.to raise_error(ArgumentError)
  end
end
