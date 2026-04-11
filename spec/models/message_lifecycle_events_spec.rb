# frozen_string_literal: true

require "rails_helper"

RSpec.describe Message, "lifecycle events" do
  let(:session) { create(:session) }

  describe "after_create_commit" do
    it "emits a MessageCreated event" do
      allow(Events::Bus).to receive(:emit)

      message = create(:message, :user_message, session:)

      expect(Events::Bus).to have_received(:emit) do |event|
        expect(event).to be_a(Events::MessageCreated)
        expect(event.message).to eq(message)
      end
    end
  end

  describe "after_update_commit" do
    it "emits a MessageUpdated event" do
      message = create(:message, :user_message, session:)

      allow(Events::Bus).to receive(:emit)
      message.update!(token_count: 42)

      expect(Events::Bus).to have_received(:emit) do |event|
        expect(event).to be_a(Events::MessageUpdated)
        expect(event.message).to eq(message)
      end
    end
  end
end
