# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::SubagentVisibilityBroadcaster do
  subject(:broadcaster) { described_class.new }

  let(:session) { create(:session) }
  let(:child) { Session.create!(parent_session: session, prompt: "task") }

  describe "#emit" do
    it "broadcasts subagent_evicted to the parent session stream" do
      event = {
        payload: {
          type: Events::SubagentEvicted::TYPE,
          session_id: session.id,
          child_id: child.id
        }
      }

      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{session.id}",
        {"action" => "subagent_evicted", "session_id" => session.id, "child_id" => child.id}
      )

      broadcaster.emit(event)
    end
  end
end
