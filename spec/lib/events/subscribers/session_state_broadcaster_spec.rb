# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::SessionStateBroadcaster do
  let(:subscriber) { described_class.new }

  def fire(session_id:, state:)
    subscriber.emit(
      name: "anima.session.state_changed",
      payload: {session_id: session_id, state: state}
    )
  end

  it "broadcasts session_state to the session stream" do
    session = Session.create!

    expect(ActionCable.server).to receive(:broadcast).with(
      "session_#{session.id}",
      {"action" => "session_state", "state" => "awaiting", "session_id" => session.id}
    )

    fire(session_id: session.id, state: "awaiting")
  end

  it "broadcasts child_state to parent stream for sub-agents" do
    parent = Session.create!
    child = Session.create!(parent_session: parent, prompt: "task")

    expect(ActionCable.server).to receive(:broadcast).with(
      "session_#{child.id}",
      {"action" => "session_state", "state" => "awaiting", "session_id" => child.id}
    ).ordered
    expect(ActionCable.server).to receive(:broadcast).with(
      "session_#{parent.id}",
      {"action" => "child_state", "state" => "awaiting", "session_id" => child.id, "child_id" => child.id}
    ).ordered

    fire(session_id: child.id, state: "awaiting")
  end

  it "does not broadcast to parent for root sessions" do
    session = Session.create!

    expect(ActionCable.server).to receive(:broadcast).once

    fire(session_id: session.id, state: "idle")
  end
end
