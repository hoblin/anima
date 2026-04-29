# frozen_string_literal: true

require "rails_helper"

RSpec.describe MeleteEnrichmentJob::GoalChangeListener do
  describe ".observe" do
    it "returns false when no matching event fires during the block" do
      result = described_class.observe(session_id: 1) do
        # nothing happens
      end

      expect(result).to be false
    end

    it "returns true when GoalCreated fires for the session" do
      result = described_class.observe(session_id: 1) do
        Events::Bus.emit(Events::GoalCreated.new(session_id: 1, goal_id: 99))
      end

      expect(result).to be true
    end

    it "returns true when GoalUpdated fires for the session" do
      result = described_class.observe(session_id: 1) do
        Events::Bus.emit(Events::GoalUpdated.new(session_id: 1, goal_id: 99))
      end

      expect(result).to be true
    end

    it "ignores goal events for other sessions" do
      result = described_class.observe(session_id: 1) do
        Events::Bus.emit(Events::GoalCreated.new(session_id: 2, goal_id: 99))
      end

      expect(result).to be false
    end

    it "ignores unrelated events" do
      result = described_class.observe(session_id: 1) do
        Events::Bus.emit(Events::SystemMessage.new(content: "hi", session_id: 1))
      end

      expect(result).to be false
    end

    it "unsubscribes after the block returns — later goal events do not flip a stale latch" do
      described_class.observe(session_id: 1) {}

      expect {
        Events::Bus.emit(Events::GoalCreated.new(session_id: 1, goal_id: 99))
      }.not_to raise_error
      # If the listener leaked, it would still be in the bus subscriber list;
      # the next observe call would inherit the previous trigger. Verify a
      # fresh observe starts clean.
      result = described_class.observe(session_id: 1) {}
      expect(result).to be false
    end

    it "unsubscribes even when the block raises" do
      expect {
        described_class.observe(session_id: 1) { raise "boom" }
      }.to raise_error("boom")

      result = described_class.observe(session_id: 1) {}
      expect(result).to be false
    end

    it "propagates the block's exception" do
      expect {
        described_class.observe(session_id: 1) { raise StandardError, "runner crashed" }
      }.to raise_error(StandardError, "runner crashed")
    end
  end
end
