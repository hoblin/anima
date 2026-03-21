# frozen_string_literal: true

require "rails_helper"

RSpec.describe PinnedEvent do
  let(:session) { Session.create! }
  let(:event) { session.events.create!(event_type: "user_message", payload: {content: "important instruction"}, timestamp: 1) }

  describe "validations" do
    it "requires display_text" do
      pin = PinnedEvent.new(event: event, display_text: nil)
      expect(pin).not_to be_valid
      expect(pin.errors[:display_text]).to be_present
    end

    it "enforces display_text max length" do
      pin = PinnedEvent.new(event: event, display_text: "x" * 201)
      expect(pin).not_to be_valid
      expect(pin.errors[:display_text]).to be_present
    end

    it "enforces event uniqueness" do
      PinnedEvent.create!(event: event, display_text: "text")
      dup = PinnedEvent.new(event: event, display_text: "text")
      expect(dup).not_to be_valid
      expect(dup.errors[:event_id]).to be_present
    end
  end

  describe "associations" do
    it "belongs to an event" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      expect(pin.event).to eq(event)
    end

    it "is accessible through session" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      expect(session.pinned_events).to eq([pin])
    end

    it "has many goals through goal_pinned_events" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      goal = session.goals.create!(description: "goal")
      GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

      expect(pin.goals).to eq([goal])
    end

    it "destroys join records when destroyed" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      goal = session.goals.create!(description: "goal")
      GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

      expect { pin.destroy }.to change(GoalPinnedEvent, :count).by(-1)
    end
  end

  describe ".orphaned" do
    it "returns pins with no active goals" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      goal = session.goals.create!(description: "done", status: "completed", completed_at: Time.current)
      GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

      expect(PinnedEvent.orphaned).to include(pin)
    end

    it "excludes pins with at least one active goal" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      goal = session.goals.create!(description: "active")
      GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

      expect(PinnedEvent.orphaned).not_to include(pin)
    end

    it "returns pins with no goal associations at all" do
      pin = PinnedEvent.create!(event: event, display_text: "test")
      expect(PinnedEvent.orphaned).to include(pin)
    end
  end

  describe "#token_cost" do
    it "estimates tokens from display_text byte size" do
      pin = PinnedEvent.new(display_text: "a" * 100)
      expect(pin.token_cost).to eq((100.0 / Event::BYTES_PER_TOKEN).ceil)
    end

    it "returns at least 1 for empty-ish text" do
      pin = PinnedEvent.new(display_text: "hi")
      expect(pin.token_cost).to be >= 1
    end
  end
end
