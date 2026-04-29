# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::GoalUpdated do
  it "serialises type, session_id, and goal_id" do
    event = described_class.new(session_id: 7, goal_id: 42)

    expect(event.to_h).to eq(type: "goal.updated", session_id: 7, goal_id: 42)
  end

  it "namespaces the event_name under the bus namespace" do
    event = described_class.new(session_id: 1, goal_id: 1)

    expect(event.event_name).to eq("anima.goal.updated")
  end

  it "requires both session_id and goal_id" do
    expect { described_class.new(session_id: 1) }.to raise_error(ArgumentError)
    expect { described_class.new(goal_id: 1) }.to raise_error(ArgumentError)
  end
end
