# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::AuthenticationBroadcaster do
  subject(:broadcaster) { described_class.new }

  let(:session) { Session.create! }

  describe "#emit" do
    it "emits a SystemMessage with the provider error text" do
      emitted = capture_emissions

      broadcaster.emit(
        name: "anima.authentication_required",
        payload: {session_id: session.id, content: "bad token"}
      )

      sys = emitted.find { |e| e.is_a?(Events::SystemMessage) }
      expect(sys).to be_present
      expect(sys.content).to include("Authentication failed", "bad token")
      expect(sys.session_id).to eq(session.id)
    end

    it "broadcasts an authentication_required frame on the session channel" do
      expect {
        broadcaster.emit(
          name: "anima.authentication_required",
          payload: {session_id: session.id, content: "bad token"}
        )
      }.to have_broadcasted_to("session_#{session.id}")
        .with(hash_including("action" => "authentication_required", "message" => "bad token"))
    end
  end
end
