# frozen_string_literal: true

require "rails_helper"

RSpec.describe Snapshot do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires text" do
      snapshot = session.snapshots.build(from_message_id: 1, to_message_id: 10, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:text]).to include("can't be blank")
    end

    it "requires from_message_id" do
      snapshot = session.snapshots.build(text: "Summary", to_message_id: 10, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:from_message_id]).to include("can't be blank")
    end

    it "requires to_message_id" do
      snapshot = session.snapshots.build(text: "Summary", from_message_id: 1, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:to_message_id]).to include("can't be blank")
    end

    it "requires level to be positive" do
      snapshot = session.snapshots.build(text: "Summary", from_message_id: 1, to_message_id: 10, level: 0)
      expect(snapshot).not_to be_valid
    end

    it "rejects from_message_id > to_message_id" do
      snapshot = session.snapshots.build(text: "Summary", from_message_id: 20, to_message_id: 10, level: 1)
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:from_message_id]).to include("must be <= to_message_id")
    end

    it "rejects negative token_count" do
      snapshot = session.snapshots.build(
        text: "Summary", from_message_id: 1, to_message_id: 10, level: 1, token_count: -1
      )
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:token_count]).to include("must be greater than or equal to 0")
    end

    it "rejects text exceeding MAX_TEXT_BYTES" do
      snapshot = session.snapshots.build(
        text: "x" * (Snapshot::MAX_TEXT_BYTES + 1),
        from_message_id: 1, to_message_id: 10, level: 1
      )
      expect(snapshot).not_to be_valid
      expect(snapshot.errors[:text]).to include(/too long/)
    end

    it "creates a valid snapshot with all required fields" do
      snapshot = session.snapshots.create!(
        text: "Summary of events", from_message_id: 1, to_message_id: 10, level: 1
      )
      expect(snapshot).to be_persisted
    end
  end

  describe "associations" do
    it "belongs to a session" do
      snapshot = session.snapshots.create!(
        text: "Summary", from_message_id: 1, to_message_id: 10, level: 1
      )
      expect(snapshot.session).to eq(session)
    end
  end

  describe "scopes" do
    before do
      session.snapshots.create!(text: "L1 first", from_message_id: 1, to_message_id: 10, level: 1, token_count: 50)
      session.snapshots.create!(text: "L1 second", from_message_id: 11, to_message_id: 20, level: 1, token_count: 50)
      session.snapshots.create!(text: "L2 first", from_message_id: 1, to_message_id: 20, level: 2, token_count: 80)
    end

    it "filters by level" do
      expect(Snapshot.for_level(1).count).to eq(2)
      expect(Snapshot.for_level(2).count).to eq(1)
    end

    it "orders chronologically by from_message_id" do
      snapshots = Snapshot.chronological.to_a
      expect(snapshots.first.from_message_id).to be <= snapshots.last.from_message_id
    end

    describe ".not_covered_by_l2" do
      it "excludes L1 snapshots fully covered by an L2 snapshot" do
        uncovered = session.snapshots.for_level(1).not_covered_by_l2
        expect(uncovered).to be_empty
      end

      it "includes L1 snapshots not covered by any L2 snapshot" do
        session.snapshots.create!(text: "L1 third", from_message_id: 21, to_message_id: 30, level: 1)

        uncovered = session.snapshots.for_level(1).not_covered_by_l2
        expect(uncovered.count).to eq(1)
        expect(uncovered.first.from_message_id).to eq(21)
      end

      it "includes L1 snapshots beyond the L2 range" do
        # L2 covers 1..20, this L1 starts after that range
        session.snapshots.create!(text: "L1 third", from_message_id: 21, to_message_id: 30, level: 1)
        session.snapshots.create!(text: "L1 fourth", from_message_id: 31, to_message_id: 40, level: 1)

        uncovered = session.snapshots.for_level(1).not_covered_by_l2
        expect(uncovered.count).to eq(2)
        expect(uncovered.pluck(:from_message_id)).to contain_exactly(21, 31)
      end

      it "does not treat partial overlap as coverage" do
        # L1 covers events 5..25, L2 covers 1..20 — L2 does NOT fully contain L1
        l1_partial = session.snapshots.create!(text: "L1 partial", from_message_id: 5, to_message_id: 25, level: 1)

        uncovered = session.snapshots.for_level(1).not_covered_by_l2
        expect(uncovered).to include(l1_partial)
      end

      it "scopes to the same session" do
        other_session = Session.create!
        other_session.snapshots.create!(text: "L1 other", from_message_id: 1, to_message_id: 10, level: 1)

        uncovered = other_session.snapshots.for_level(1).not_covered_by_l2
        expect(uncovered.count).to eq(1)
      end
    end


  end

  describe "#token_cost" do
    it "returns cached token_count when positive" do
      snapshot = session.snapshots.create!(
        text: "Summary", from_message_id: 1, to_message_id: 10, level: 1, token_count: 42
      )
      expect(snapshot.token_cost).to eq(42)
    end

    it "estimates token count when token_count is zero" do
      snapshot = session.snapshots.create!(
        text: "A" * 400, from_message_id: 1, to_message_id: 10, level: 1, token_count: 0
      )
      expect(snapshot.token_cost).to eq(100) # 400 bytes / 4 bytes per token
    end
  end

  describe "session association" do
    it "is destroyed when the session is destroyed" do
      session.snapshots.create!(text: "Summary", from_message_id: 1, to_message_id: 10, level: 1)
      expect { session.destroy }.to change(Snapshot, :count).by(-1)
    end
  end
end
