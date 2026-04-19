# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::MnemeKickoff do
  subject(:kickoff) { described_class.new }

  describe "#emit" do
    it "enqueues MnemeEnrichmentJob with session_id and pending_message_id" do
      expect {
        kickoff.emit(
          name: "anima.session.start_mneme",
          payload: {session_id: 42, pending_message_id: 7}
        )
      }.to have_enqueued_job(MnemeEnrichmentJob).with(42, pending_message_id: 7)
    end

    it "does nothing when session_id is missing" do
      expect {
        kickoff.emit(name: "anima.session.start_mneme", payload: {})
      }.not_to have_enqueued_job(MnemeEnrichmentJob)
    end
  end
end
