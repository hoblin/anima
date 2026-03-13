# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::ActionCableBridge do
  subject(:bridge) { described_class.instance }

  describe "#emit" do
    it "is a no-op (broadcasting moved to Event::Broadcasting)" do
      expect {
        bridge.emit(event_hash(Events::UserMessage.new(content: "hello", session_id: 42)))
      }.not_to have_broadcasted_to("session_42")
    end

    it "returns nil" do
      result = bridge.emit(event_hash(Events::UserMessage.new(content: "hello", session_id: 42)))
      expect(result).to be_nil
    end
  end

  describe "subscriber interface" do
    it "includes Events::Subscriber" do
      expect(bridge).to be_a(Events::Subscriber)
    end
  end

  def event_hash(event)
    {name: event.event_name, payload: event.to_h, timestamp: event.timestamp}
  end
end
