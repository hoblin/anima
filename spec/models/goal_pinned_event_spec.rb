# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoalPinnedEvent do
  let(:session) { Session.create! }
  let(:event) { session.events.create!(event_type: "user_message", payload: {content: "text"}, timestamp: 1) }
  let(:goal) { session.goals.create!(description: "goal") }
  let(:pinned_event) { PinnedEvent.create!(event: event, display_text: "text") }

  describe "validations" do
    it "enforces pinned_event uniqueness per goal" do
      GoalPinnedEvent.create!(goal: goal, pinned_event: pinned_event)
      dup = GoalPinnedEvent.new(goal: goal, pinned_event: pinned_event)
      expect(dup).not_to be_valid
      expect(dup.errors[:pinned_event_id]).to be_present
    end
  end

  describe "associations" do
    it "belongs to a goal and pinned_event" do
      gpe = GoalPinnedEvent.create!(goal: goal, pinned_event: pinned_event)
      expect(gpe.goal).to eq(goal)
      expect(gpe.pinned_event).to eq(pinned_event)
    end
  end
end
