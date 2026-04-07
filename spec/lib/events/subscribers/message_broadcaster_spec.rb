# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::MessageBroadcaster do
  subject(:broadcaster) { described_class.new }

  let(:session) { create(:session) }

  describe "#emit" do
    context "with a message.created event" do
      it "broadcasts the message payload with action 'create'" do
        message = create(:message, :user_message, session:)
        event = {payload: {type: Events::MessageCreated::TYPE, message:}}

        expect(ActionCable.server).to receive(:broadcast)
          .with("session_#{session.id}", hash_including("action" => "create", "id" => message.id))

        broadcaster.emit(event)
      end
    end

    context "with a message.updated event" do
      it "broadcasts the message payload with action 'update'" do
        message = create(:message, :user_message, session:)
        event = {payload: {type: Events::MessageUpdated::TYPE, message:}}

        expect(ActionCable.server).to receive(:broadcast)
          .with("session_#{session.id}", hash_including("action" => "update", "id" => message.id))

        broadcaster.emit(event)
      end
    end
  end
end
