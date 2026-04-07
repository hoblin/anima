# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::EvictionBroadcaster do
  subject(:broadcaster) { described_class.new }

  let(:session) { create(:session) }

  describe "#emit" do
    it "broadcasts eviction cutoff to the session stream" do
      event = {payload: {type: Events::EvictionCompleted::TYPE, session_id: session.id, evict_above_id: 42}}

      expect(ActionCable.server).to receive(:broadcast)
        .with("session_#{session.id}", {"action" => "eviction", "evict_above_id" => 42})

      broadcaster.emit(event)
    end
  end
end
