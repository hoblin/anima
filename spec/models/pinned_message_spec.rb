# frozen_string_literal: true

require "rails_helper"

RSpec.describe PinnedMessage do
  let(:session) { Session.create! }
  let(:message) { session.messages.create!(message_type: "user_message", payload: {content: "important instruction"}, timestamp: 1) }

  describe "validations" do
    it "requires display_text" do
      pin = PinnedMessage.new(message: message, display_text: nil)
      expect(pin).not_to be_valid
      expect(pin.errors[:display_text]).to be_present
    end

    it "enforces display_text max length" do
      pin = PinnedMessage.new(message: message, display_text: "x" * 201)
      expect(pin).not_to be_valid
      expect(pin.errors[:display_text]).to be_present
    end

    it "enforces message uniqueness" do
      PinnedMessage.create!(message: message, display_text: "text")
      dup = PinnedMessage.new(message: message, display_text: "text")
      expect(dup).not_to be_valid
      expect(dup.errors[:message_id]).to be_present
    end
  end

  describe "associations" do
    it "belongs to a message" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      expect(pin.message).to eq(message)
    end

    it "is accessible through session" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      expect(session.pinned_messages).to eq([pin])
    end

    it "has many goals through goal_pinned_messages" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      goal = session.goals.create!(description: "goal")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect(pin.goals).to eq([goal])
    end

    it "destroys join records when destroyed" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      goal = session.goals.create!(description: "goal")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect { pin.destroy }.to change(GoalPinnedMessage, :count).by(-1)
    end
  end

  describe ".orphaned" do
    it "returns pins with no active goals" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      goal = session.goals.create!(description: "done", status: "completed", completed_at: Time.current)
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect(PinnedMessage.orphaned).to include(pin)
    end

    it "excludes pins with at least one active goal" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      goal = session.goals.create!(description: "active")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect(PinnedMessage.orphaned).not_to include(pin)
    end

    it "returns pins with no goal associations at all" do
      pin = PinnedMessage.create!(message: message, display_text: "test")
      expect(PinnedMessage.orphaned).to include(pin)
    end
  end

  describe "#tokenization_text" do
    it "returns the pin's display_text" do
      pin = PinnedMessage.new(display_text: "important note")
      expect(pin.tokenization_text).to eq("important note")
    end
  end

  describe "token_count seeding" do
    it "seeds token_count from display_text on create" do
      pin = PinnedMessage.create!(message: message, display_text: "a" * 100)
      expect(pin.token_count).to eq(TokenEstimation.estimate_token_count("a" * 100))
    end

    it "respects an explicit positive value passed by the caller" do
      pin = PinnedMessage.create!(message: message, display_text: "hi", token_count: 42)
      expect(pin.token_count).to eq(42)
    end

    it "enqueues CountTokensJob for the pin after create" do
      message # materialize the message first so its own job is already enqueued
      expect {
        PinnedMessage.create!(message: message, display_text: "test")
      }.to have_enqueued_job(CountTokensJob).with(an_instance_of(PinnedMessage))
    end
  end
end
