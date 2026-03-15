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
        goal.update!(status: "completed", completed_at: Time.current)
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
