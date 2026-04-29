# frozen_string_literal: true

require "rails_helper"

RSpec.describe Goal do
  let(:session) { create(:session) }

  describe "custom validations" do
    it "rejects a parent_goal that belongs to a different session" do
      parent = create(:goal, session: create(:session))

      child = build(:goal, session: session, parent_goal: parent)

      expect(child).not_to be_valid
      expect(child.errors[:parent_goal]).to include("must belong to the same session")
    end

    it "rejects nesting deeper than two levels" do
      root = create(:goal, session: session)
      child = create(:goal, session: session, parent_goal: root)

      grandchild = build(:goal, session: session, parent_goal: child)

      expect(grandchild).not_to be_valid
      expect(grandchild.errors[:parent_goal]).to include("cannot nest deeper than two levels")
    end

    it "rejects a status outside the STATUSES list" do
      goal = build(:goal, session: session, status: "cancelled")

      expect(goal).not_to be_valid
      expect(goal.errors[:status]).to be_present
    end
  end

  describe "scopes" do
    let!(:active) { create(:goal, session: session, description: "active") }
    let!(:completed) { create(:goal, :completed, session: session, description: "done") }
    let!(:evicted) { create(:goal, :evicted, session: session, description: "gone") }
    let!(:sub) { create(:goal, session: session, parent_goal: active, description: "sub") }

    it ".active returns only goals with status=active" do
      expect(Goal.active).to contain_exactly(active, sub)
    end

    it ".completed returns only goals with status=completed" do
      expect(Goal.completed).to contain_exactly(completed, evicted)
    end

    it ".root returns only goals without a parent_goal" do
      expect(Goal.root).to contain_exactly(active, completed, evicted)
    end

    it ".not_evicted returns goals with no evicted_at" do
      expect(Goal.not_evicted).to contain_exactly(active, completed, sub)
    end

    it ".evictable returns completed goals that have not yet been evicted" do
      expect(Goal.evictable).to contain_exactly(completed)
    end
  end

  describe "predicate helpers" do
    it "#completed? reflects status" do
      expect(create(:goal, :completed, session: session)).to be_completed
      expect(create(:goal, session: session)).not_to be_completed
    end

    it "#root? is true when parent_goal_id is nil" do
      root = create(:goal, session: session)
      sub = create(:goal, session: session, parent_goal: root)

      expect(root).to be_root
      expect(sub).not_to be_root
    end

    it "#evicted? reflects evicted_at presence" do
      expect(create(:goal, :evicted, session: session)).to be_evicted
      expect(create(:goal, :completed, session: session)).not_to be_evicted
    end
  end

  describe "#cascade_completion!" do
    let(:root) { create(:goal, session: session) }

    it "completes all active sub-goals in one shot" do
      sub_a = create(:goal, session: session, parent_goal: root)
      sub_b = create(:goal, session: session, parent_goal: root)

      root.cascade_completion!

      expect(sub_a.reload).to be_completed
      expect(sub_a.completed_at).to be_within(1.second).of(Time.current)
      expect(sub_b.reload).to be_completed
    end

    it "leaves already-completed sub-goals untouched (preserves their completed_at)" do
      done = create(:goal, :completed, session: session, parent_goal: root, completed_at: 1.hour.ago)
      active = create(:goal, session: session, parent_goal: root)

      root.cascade_completion!

      expect(active.reload).to be_completed
      expect(done.reload.completed_at).to be_within(1.second).of(1.hour.ago)
    end

    it "no-ops when the goal has no sub-goals" do
      expect { root.cascade_completion! }.not_to raise_error
    end
  end

  describe "#release_orphaned_pins!" do
    let(:message) { create(:message, :user_message, session: session) }

    it "destroys pins orphaned by this goal's completion" do
      goal = create(:goal, :completed, session: session)
      pin = PinnedMessage.create!(message: message, display_text: "text")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect { goal.release_orphaned_pins! }.to change(PinnedMessage, :count).by(-1)
    end

    it "keeps pins still referenced by other active goals" do
      completed = create(:goal, :completed, session: session)
      still_active = create(:goal, session: session)
      pin = PinnedMessage.create!(message: message, display_text: "text")
      GoalPinnedMessage.create!(goal: completed, pinned_message: pin)
      GoalPinnedMessage.create!(goal: still_active, pinned_message: pin)

      expect { completed.release_orphaned_pins! }.not_to change(PinnedMessage, :count)
    end

    it "returns the number of pins released" do
      goal = create(:goal, :completed, session: session)
      pin = PinnedMessage.create!(message: message, display_text: "text")
      GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

      expect(goal.release_orphaned_pins!).to eq(1)
    end

    it "returns zero when the goal has no associated pins" do
      goal = create(:goal, session: session)
      expect(goal.release_orphaned_pins!).to eq(0)
    end
  end

  describe "#as_summary" do
    it "includes id, description, status, and ordered sub_goals" do
      root = create(:goal, session: session, description: "root")
      first = create(:goal, session: session, parent_goal: root, description: "first")
      second = create(:goal, :completed, session: session, parent_goal: root, description: "second")

      summary = root.reload.as_summary

      expect(summary).to include(
        "id" => root.id,
        "description" => "root",
        "status" => "active"
      )
      expect(summary["sub_goals"]).to eq([
        {"id" => first.id, "description" => "first", "status" => "active"},
        {"id" => second.id, "description" => "second", "status" => "completed"}
      ])
    end

    it "returns an empty sub_goals array for standalone root goals" do
      goal = create(:goal, session: session)
      expect(goal.as_summary["sub_goals"]).to eq([])
    end
  end

  describe "goal mutation events" do
    before { allow(Events::Bus).to receive(:emit).and_call_original }

    it "emits GoalCreated on create" do
      goal = create(:goal, session: session)

      expect(Events::Bus).to have_received(:emit).with(
        an_instance_of(Events::GoalCreated)
          .and(have_attributes(session_id: session.id, goal_id: goal.id))
      )
    end

    it "emits GoalUpdated when description changes" do
      goal = create(:goal, session: session)

      goal.update!(description: "revised")

      expect(Events::Bus).to have_received(:emit).with(
        an_instance_of(Events::GoalUpdated)
          .and(have_attributes(session_id: session.id, goal_id: goal.id))
      )
    end

    it "stays silent on status-only updates (finish_goal / mark_goal_completed)" do
      goal = create(:goal, session: session)

      goal.update!(status: "completed", completed_at: Time.current)

      expect(Events::Bus).not_to have_received(:emit).with(an_instance_of(Events::GoalUpdated))
    end

    it "stays silent on cascade completion (update_all skips callbacks)" do
      root = create(:goal, session: session)
      sub = create(:goal, session: session, parent_goal: root)

      root.cascade_completion!

      expect(sub.reload.status).to eq("completed")
      expect(Events::Bus).not_to have_received(:emit).with(an_instance_of(Events::GoalUpdated))
    end
  end

  describe "ActionCable goals_updated broadcast" do
    it "fires on create, update, and destroy — carrying the full goals_summary" do
      goal = nil

      expect { goal = create(:goal, session: session, description: "first goal") }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "goals_updated",
          "session_id" => session.id,
          "goals" => a_collection_including(a_hash_including("description" => "first goal"))
        ))

      expect { goal.update!(status: "completed") }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "goals_updated"))

      expect { goal.destroy! }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "goals_updated"))
    end
  end
end
