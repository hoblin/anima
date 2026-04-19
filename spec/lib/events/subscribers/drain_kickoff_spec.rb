# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::DrainKickoff do
  subject(:kickoff) { described_class.new }

  describe "#emit" do
    it "enqueues DrainJob with the session_id from the event payload" do
      expect {
        kickoff.emit(name: "anima.session.start_processing", payload: {session_id: 42})
      }.to have_enqueued_job(DrainJob).with(42)
    end

    it "does nothing when session_id is missing" do
      expect {
        kickoff.emit(name: "anima.session.start_processing", payload: {})
      }.not_to have_enqueued_job(DrainJob)
    end
  end
end
