# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::MnemeScheduler do
  subject(:scheduler) { described_class.new }

  let(:session) { create(:session) }

  describe "#emit" do
    it "calls schedule_mneme! on the message's session" do
      message = create(:message, :user_message, session:)
      event = {payload: {type: Events::MessageCreated::TYPE, message:}}

      allow(message.session).to receive(:schedule_mneme!)
      scheduler.emit(event)

      expect(message.session).to have_received(:schedule_mneme!)
    end
  end
end
