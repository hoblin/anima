# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::ActiveStateBroadcaster do
  subject(:subscriber) { described_class.new }

  let(:session) { create(:session) }

  describe "#emit" do
    it "calls broadcast_active_state! on the session referenced by the event" do
      event = {payload: {session_id: session.id}}
      allow(Session).to receive(:find_by).with(id: session.id).and_return(session)
      allow(session).to receive(:broadcast_active_state!)

      subscriber.emit(event)

      expect(session).to have_received(:broadcast_active_state!)
    end

    it "is a no-op when the session has been deleted" do
      event = {payload: {session_id: -1}}

      expect { subscriber.emit(event) }.not_to raise_error
    end

    it "is a no-op when the event payload has no session_id" do
      event = {payload: {}}

      expect { subscriber.emit(event) }.not_to raise_error
    end
  end
end
