# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::TransientBroadcaster do
  subject(:broadcaster) { described_class.new }

  let(:session) { Session.create! }

  describe "#emit" do
    it "broadcasts bounce_back events to the session stream" do
      event = {
        payload: {
          type: "bounce_back", content: "hello",
          error: "Auth failed", session_id: session.id, event_id: 42
        }
      }

      expect {
        broadcaster.emit(event)
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("type" => "bounce_back", "content" => "hello"))
    end

    it "ignores non-transient event types" do
      event = {
        payload: {type: "user_message", content: "hello", session_id: session.id}
      }

      expect(ActionCable.server).not_to receive(:broadcast)
      broadcaster.emit(event)
    end

    it "ignores events without session_id" do
      event = {
        payload: {type: "bounce_back", content: "hello", error: "err", session_id: nil}
      }

      expect(ActionCable.server).not_to receive(:broadcast)
      broadcaster.emit(event)
    end
  end
end
