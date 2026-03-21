# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Tools::AttachEventsToGoals do
  let(:session) { Session.create! }

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("attach_events_to_goals") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("attach_events_to_goals")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to include("event_ids", "goal_ids")
    end
  end

  describe "#execute" do
    let(:tool) { described_class.new(main_session: session) }
    let(:event1) { session.events.create!(event_type: "user_message", payload: {content: "Do this important thing"}, timestamp: 1) }
    let(:event2) { session.events.create!(event_type: "agent_message", payload: {content: "Understood, I will do it"}, timestamp: 2) }
    let(:goal) { session.goals.create!(description: "Important task") }

    it "creates pinned event records and join records" do
      expect {
        tool.execute("event_ids" => [event1.id], "goal_ids" => [goal.id])
      }.to change(PinnedEvent, :count).by(1)
        .and change(GoalPinnedEvent, :count).by(1)
    end

    it "returns a confirmation with link count" do
      result = tool.execute("event_ids" => [event1.id], "goal_ids" => [goal.id])
      expect(result).to eq("Pinned 1 event-goal links")
    end

    it "pins multiple events to multiple goals" do
      goal2 = session.goals.create!(description: "Another task")

      result = tool.execute("event_ids" => [event1.id, event2.id], "goal_ids" => [goal.id, goal2.id])
      expect(result).to eq("Pinned 4 event-goal links")
      expect(PinnedEvent.count).to eq(2)
      expect(GoalPinnedEvent.count).to eq(4)
    end

    it "truncates display_text to 200 chars" do
      long_event = session.events.create!(
        event_type: "user_message",
        payload: {content: "x" * 300},
        timestamp: 3
      )

      tool.execute("event_ids" => [long_event.id], "goal_ids" => [goal.id])
      pin = PinnedEvent.last
      expect(pin.display_text.length).to eq(200)
      expect(pin.display_text).to end_with("…")
    end

    it "reuses existing PinnedEvent when pinning to additional goals" do
      tool.execute("event_ids" => [event1.id], "goal_ids" => [goal.id])

      goal2 = session.goals.create!(description: "Second goal")
      expect {
        tool.execute("event_ids" => [event1.id], "goal_ids" => [goal2.id])
      }.to change(PinnedEvent, :count).by(0)
        .and change(GoalPinnedEvent, :count).by(1)
    end

    it "is idempotent for duplicate pin+goal combos" do
      tool.execute("event_ids" => [event1.id], "goal_ids" => [goal.id])

      expect {
        tool.execute("event_ids" => [event1.id], "goal_ids" => [goal.id])
      }.to change(GoalPinnedEvent, :count).by(0)
    end

    it "returns error for empty event_ids" do
      result = tool.execute("event_ids" => [], "goal_ids" => [goal.id])
      expect(result).to eq("Error: event_ids cannot be empty")
    end

    it "returns error for empty goal_ids" do
      result = tool.execute("event_ids" => [event1.id], "goal_ids" => [])
      expect(result).to eq("Error: goal_ids cannot be empty")
    end

    it "returns error when events not found" do
      result = tool.execute("event_ids" => [999], "goal_ids" => [goal.id])
      expect(result).to include("Events not found: 999")
    end

    it "returns error when goals not found or inactive" do
      completed_goal = session.goals.create!(description: "Done", status: "completed", completed_at: Time.current)
      result = tool.execute("event_ids" => [event1.id], "goal_ids" => [completed_goal.id])
      expect(result).to include("Active goals not found:")
    end

    it "returns combined errors for missing events and goals" do
      result = tool.execute("event_ids" => [999], "goal_ids" => [888])
      expect(result).to include("Events not found: 999")
      expect(result).to include("Active goals not found: 888")
    end
  end
end
