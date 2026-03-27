# frozen_string_literal: true

require "rails_helper"

RSpec.describe Goal do
  describe "validations" do
    it "requires a description" do
      goal = Goal.new(session: Session.create!, description: nil)
      expect(goal).not_to be_valid
      expect(goal.errors[:description]).to be_present
    end

    it "accepts valid statuses" do
      session = Session.create!
      %w[active completed].each do |status|
        goal = Goal.new(session: session, description: "test", status: status)
        expect(goal).to be_valid
      end
    end

    it "rejects invalid statuses" do
      goal = Goal.new(session: Session.create!, description: "test", status: "cancelled")
      expect(goal).not_to be_valid
      expect(goal.errors[:status]).to be_present
    end

    it "defaults status to active" do
      goal = Goal.create!(session: Session.create!, description: "test")
      expect(goal.status).to eq("active")
    end

    it "rejects parent_goal from a different session" do
      session_a = Session.create!
      session_b = Session.create!
      parent = Goal.create!(session: session_a, description: "parent")

      child = Goal.new(session: session_b, parent_goal: parent, description: "orphan")
      expect(child).not_to be_valid
      expect(child.errors[:parent_goal]).to include("must belong to the same session")
    end

    it "rejects nesting deeper than two levels" do
      session = Session.create!
      root = Goal.create!(session: session, description: "root")
      child = Goal.create!(session: session, parent_goal: root, description: "child")

      grandchild = Goal.new(session: session, parent_goal: child, description: "grandchild")
      expect(grandchild).not_to be_valid
      expect(grandchild.errors[:parent_goal]).to include("cannot nest deeper than two levels")
    end
  end

  describe "associations" do
    it "belongs to a session" do
      session = Session.create!
      goal = Goal.create!(session: session, description: "test")
      expect(goal.session).to eq(session)
    end

    it "belongs to a parent goal (optional)" do
      session = Session.create!
      parent = Goal.create!(session: session, description: "parent")
      child = Goal.create!(session: session, parent_goal: parent, description: "child")

      expect(child.parent_goal).to eq(parent)
    end

    it "allows goals without a parent" do
      goal = Goal.create!(session: Session.create!, description: "root goal")
      expect(goal.parent_goal).to be_nil
    end

    it "has many sub_goals" do
      session = Session.create!
      parent = Goal.create!(session: session, description: "parent")
      sub_a = Goal.create!(session: session, parent_goal: parent, description: "sub A")
      sub_b = Goal.create!(session: session, parent_goal: parent, description: "sub B")

      expect(parent.sub_goals).to contain_exactly(sub_a, sub_b)
    end

    it "destroys sub_goals when parent is destroyed" do
      session = Session.create!
      parent = Goal.create!(session: session, description: "parent")
      Goal.create!(session: session, parent_goal: parent, description: "child")

      expect { parent.destroy }.to change(Goal, :count).by(-2)
    end

    it "is destroyed when session is destroyed" do
      session = Session.create!
      Goal.create!(session: session, description: "test")

      expect { session.destroy }.to change(Goal, :count).by(-1)
    end
  end

  describe "scopes" do
    let(:session) { Session.create! }

    it ".active returns only active goals" do
      active = Goal.create!(session: session, description: "active")
      Goal.create!(session: session, description: "done", status: "completed")

      expect(Goal.active).to eq([active])
    end

    it ".completed returns only completed goals" do
      Goal.create!(session: session, description: "active")
      done = Goal.create!(session: session, description: "done", status: "completed")

      expect(Goal.completed).to eq([done])
    end

    it ".root returns only goals without a parent" do
      root = Goal.create!(session: session, description: "root")
      Goal.create!(session: session, parent_goal: root, description: "child")

      expect(Goal.root).to eq([root])
    end
  end

  describe "#completed?" do
    let(:session) { Session.create! }

    it "returns true for completed goals" do
      goal = Goal.create!(session: session, description: "done", status: "completed")
      expect(goal).to be_completed
    end

    it "returns false for active goals" do
      goal = Goal.create!(session: session, description: "active")
      expect(goal).not_to be_completed
    end
  end

  describe "#root?" do
    let(:session) { Session.create! }

    it "returns true for goals without a parent" do
      goal = Goal.create!(session: session, description: "root")
      expect(goal).to be_root
    end

    it "returns false for sub-goals" do
      root = Goal.create!(session: session, description: "root")
      sub = Goal.create!(session: session, parent_goal: root, description: "sub")
      expect(sub).not_to be_root
    end
  end

  describe "#cascade_completion!" do
    let(:session) { Session.create! }

    it "completes all active sub-goals" do
      root = Goal.create!(session: session, description: "root")
      sub_a = Goal.create!(session: session, parent_goal: root, description: "A")
      sub_b = Goal.create!(session: session, parent_goal: root, description: "B")

      root.cascade_completion!

      expect(sub_a.reload.status).to eq("completed")
      expect(sub_a.completed_at).to be_within(1.second).of(Time.current)
      expect(sub_b.reload.status).to eq("completed")
      expect(sub_b.completed_at).to be_within(1.second).of(Time.current)
    end

    it "skips already completed sub-goals" do
      root = Goal.create!(session: session, description: "root")
      done = Goal.create!(session: session, parent_goal: root, description: "done",
        status: "completed", completed_at: 1.hour.ago)
      active = Goal.create!(session: session, parent_goal: root, description: "active")

      root.cascade_completion!

      expect(active.reload.status).to eq("completed")
      expect(done.reload.completed_at).to be_within(1.second).of(1.hour.ago)
    end

    it "is a no-op when there are no sub-goals" do
      root = Goal.create!(session: session, description: "standalone")

      expect { root.cascade_completion! }.not_to raise_error
    end
  end

  describe "#release_orphaned_pins!" do
    let(:session) { Session.create! }
    let(:msg) { session.messages.create!(message_type: "user_message", payload: {content: "text"}, timestamp: 1) }

    it "destroys pins with no remaining active goals" do
      goal = Goal.create!(session: session, description: "sole goal", status: "completed", completed_at: Time.current)
      pin = PinnedMessage.create!(message: msg, display_text: "text")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect { goal.release_orphaned_pins! }.to change(PinnedMessage, :count).by(-1)
    end

    it "keeps pins referenced by other active goals" do
      goal_a = Goal.create!(session: session, description: "completed", status: "completed", completed_at: Time.current)
      goal_b = Goal.create!(session: session, description: "still active")
      pin = PinnedMessage.create!(message: msg, display_text: "text")
      GoalPinnedMessage.create!(goal: goal_a, pinned_message: pin)
      GoalPinnedMessage.create!(goal: goal_b, pinned_message: pin)

      expect { goal_a.release_orphaned_pins! }.not_to change(PinnedMessage, :count)
    end

    it "returns the count of released pins" do
      goal = Goal.create!(session: session, description: "done", status: "completed", completed_at: Time.current)
      pin = PinnedMessage.create!(message: msg, display_text: "text")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect(goal.release_orphaned_pins!).to eq(1)
    end

    it "returns zero when nothing to release" do
      goal = Goal.create!(session: session, description: "no pins")
      expect(goal.release_orphaned_pins!).to eq(0)
    end
  end

  describe "pinned message associations" do
    let(:session) { Session.create! }

    it "has many pinned_messages through goal_pinned_messages" do
      goal = Goal.create!(session: session, description: "goal")
      msg = session.messages.create!(message_type: "user_message", payload: {content: "text"}, timestamp: 1)
      pin = PinnedMessage.create!(message: msg, display_text: "text")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect(goal.pinned_messages).to eq([pin])
    end

    it "destroys join records when goal is destroyed" do
      goal = Goal.create!(session: session, description: "goal")
      msg = session.messages.create!(message_type: "user_message", payload: {content: "text"}, timestamp: 1)
      pin = PinnedMessage.create!(message: msg, display_text: "text")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect { goal.destroy }.to change(GoalPinnedMessage, :count).by(-1)
      # PinnedMessage itself survives (could be referenced by other goals)
      expect(PinnedMessage.find_by(id: pin.id)).to be_present
    end
  end

  describe "#as_summary" do
    let(:session) { Session.create! }

    it "returns hash with string keys" do
      goal = Goal.create!(session: session, description: "test")

      summary = goal.as_summary
      expect(summary.keys).to eq(%w[id description status sub_goals])
    end

    it "includes goal attributes" do
      goal = Goal.create!(session: session, description: "Implement auth", status: "completed")

      summary = goal.as_summary
      expect(summary["id"]).to eq(goal.id)
      expect(summary["description"]).to eq("Implement auth")
      expect(summary["status"]).to eq("completed")
    end

    it "returns empty sub_goals array for root goals without children" do
      goal = Goal.create!(session: session, description: "standalone")

      expect(goal.as_summary["sub_goals"]).to eq([])
    end

    it "includes sub-goals ordered by created_at" do
      root = Goal.create!(session: session, description: "root")
      first = Goal.create!(session: session, parent_goal: root, description: "first")
      second = Goal.create!(session: session, parent_goal: root, description: "second")

      sub_goals = root.reload.as_summary["sub_goals"]
      expect(sub_goals.map { |sg| sg["id"] }).to eq([first.id, second.id])
    end

    it "serializes sub-goals with id, description, status" do
      root = Goal.create!(session: session, description: "root")
      Goal.create!(session: session, parent_goal: root, description: "child", status: "completed")

      sub = root.reload.as_summary["sub_goals"].first
      expect(sub.keys).to eq(%w[id description status])
      expect(sub["description"]).to eq("child")
      expect(sub["status"]).to eq("completed")
    end
  end

  describe "#schedule_passive_recall" do
    it "enqueues PassiveRecallJob on goal create" do
      session = Session.create!

      expect {
        Goal.create!(session: session, description: "new goal")
      }.to have_enqueued_job(PassiveRecallJob).with(session.id)
    end

    it "enqueues PassiveRecallJob on goal update" do
      session = Session.create!
      goal = Goal.create!(session: session, description: "original")

      expect {
        goal.update!(description: "updated")
      }.to have_enqueued_job(PassiveRecallJob).with(session.id)
    end

    it "skips enqueue for sub-agent sessions" do
      parent = Session.create!
      sub_agent_session = Session.create!(parent_session: parent)

      expect {
        Goal.create!(session: sub_agent_session, description: "sub-agent goal")
      }.not_to have_enqueued_job(PassiveRecallJob)
    end
  end

  describe "ActionCable broadcast" do
    let(:session) { Session.create! }

    it "broadcasts goals_updated on create" do
      expect {
        Goal.create!(session: session, description: "new goal")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "goals_updated",
          "session_id" => session.id
        ))
    end

    it "broadcasts goals_updated on status change" do
      goal = Goal.create!(session: session, description: "in progress")

      expect {
        goal.update!(status: "completed")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "goals_updated"))
    end

    it "broadcasts goals_updated on destroy" do
      goal = Goal.create!(session: session, description: "doomed")

      expect {
        goal.destroy!
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "goals_updated"))
    end

    it "includes goals_summary in the broadcast payload" do
      Goal.create!(session: session, description: "first goal")

      expect {
        Goal.create!(session: session, description: "second goal")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "goals" => a_collection_including(
            a_hash_including("description" => "first goal"),
            a_hash_including("description" => "second goal")
          )
        ))
    end
  end
end
