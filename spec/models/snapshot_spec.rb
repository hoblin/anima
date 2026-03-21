# frozen_string_literal: true

require "rails_helper"

RSpec.describe Snapshot do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires text" do
      snapshot = session.snapshots.build(from_event_id: 1, to_event_id: 10, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:text]).to include("can't be blank")
    end

    it "requires from_event_id" do
      snapshot = session.snapshots.build(text: "Summary", to_event_id: 10, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:from_event_id]).to include("can't be blank")
    end

    it "requires to_event_id" do
      snapshot = session.snapshots.build(text: "Summary", from_event_id: 1, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:to_event_id]).to include("can't be blank")
    end

    it "requires level to be positive" do
      snapshot = session.snapshots.build(text: "Summary", from_event_id: 1, to_event_id: 10, level: 0)
      expect(snapshot).not_to be_valid
    end

    it "creates a valid snapshot with all required fields" do
      snapshot = session.snapshots.create!(
        text: "Summary of events", from_event_id: 1, to_event_id: 10, level: 1
      )
      expect(snapshot).to be_persisted
    end
  end

  describe "associations" do
    it "belongs to a session" do
      snapshot = session.snapshots.create!(
        text: "Summary", from_event_id: 1, to_event_id: 10, level: 1
      )
      expect(snapshot.session).to eq(session)
    end
  end

  describe "scopes" do
    before do
      session.snapshots.create!(text: "L1 first", from_event_id: 1, to_event_id: 10, level: 1)
      session.snapshots.create!(text: "L1 second", from_event_id: 11, to_event_id: 20, level: 1)
      session.snapshots.create!(text: "L2 first", from_event_id: 1, to_event_id: 20, level: 2)
    end

    it "filters by level" do
      expect(Snapshot.for_level(1).count).to eq(2)
      expect(Snapshot.for_level(2).count).to eq(1)
    end

    it "orders chronologically by from_event_id" do
      snapshots = Snapshot.chronological.to_a
      expect(snapshots.first.from_event_id).to be <= snapshots.last.from_event_id
    end
  end

  describe "session association" do
    it "is destroyed when the session is destroyed" do
      session.snapshots.create!(text: "Summary", from_event_id: 1, to_event_id: 10, level: 1)
      expect { session.destroy }.to change(Snapshot, :count).by(-1)
    end
  end
end
