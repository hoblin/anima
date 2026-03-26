# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoalPinnedMessage do
  let(:session) { Session.create! }
  let(:message) { session.messages.create!(message_type: "user_message", payload: {content: "text"}, timestamp: 1) }
  let(:goal) { session.goals.create!(description: "goal") }
  let(:pinned_message) { PinnedMessage.create!(message: message, display_text: "text") }

  describe "validations" do
    it "enforces pinned_message uniqueness per goal" do
      GoalPinnedMessage.create!(goal: goal, pinned_message: pinned_message)
      dup = GoalPinnedMessage.new(goal: goal, pinned_message: pinned_message)
      expect(dup).not_to be_valid
      expect(dup.errors[:pinned_message_id]).to be_present
    end
  end

  describe "associations" do
    it "belongs to a goal and pinned_message" do
      gpe = GoalPinnedMessage.create!(goal: goal, pinned_message: pinned_message)
      expect(gpe.goal).to eq(goal)
      expect(gpe.pinned_message).to eq(pinned_message)
    end
  end
end
