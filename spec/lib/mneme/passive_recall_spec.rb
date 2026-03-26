# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::PassiveRecall do
  let(:session) { Session.create! }

  def create_message(sess, type:, content:)
    sess.messages.create!(
      message_type: type,
      payload: {"content" => content},
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    )
  end

  describe "#call" do
    it "returns empty when no active goals" do
      results = described_class.new(session).call

      expect(results).to eq([])
    end

    it "returns empty when goals exist but no matching events" do
      session.goals.create!(description: "Implement quantum teleportation")

      results = described_class.new(session).call

      expect(results).to eq([])
    end

    it "finds events matching active goal descriptions" do
      other_session = Session.create!
      event = create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      session.goals.create!(description: "Fix the authentication flow")

      results = described_class.new(session).call

      expect(results.map(&:message_id)).to include(event.id)
    end

    it "excludes events already in the current viewport" do
      # Message in current session's viewport
      event = create_message(session, type: "user_message",
        content: "Authentication is broken")
      session.update_column(:viewport_message_ids, [event.id])

      session.goals.create!(description: "Fix authentication")

      results = described_class.new(session).call

      expect(results.map(&:message_id)).not_to include(event.id)
    end

    it "includes sub-goal descriptions in search terms" do
      other_session = Session.create!
      event = create_message(other_session, type: "user_message",
        content: "The OAuth token refresh logic is wrong.")

      root = session.goals.create!(description: "Fix authentication")
      root.sub_goals.create!(session: session, description: "Fix OAuth token refresh")

      results = described_class.new(session).call

      expect(results.map(&:message_id)).to include(event.id)
    end

    it "ignores completed sub-goals" do
      other_session = Session.create!
      create_message(other_session, type: "user_message",
        content: "The PKCE implementation details.")

      root = session.goals.create!(description: "Fix auth")
      root.sub_goals.create!(session: session, description: "Check PKCE implementation",
        status: "completed", completed_at: Time.current)

      results = described_class.new(session).call

      # Should not find PKCE-related events since that sub-goal is completed
      pkce_results = results.select { |r| r.snippet&.include?("PKCE") }
      expect(pkce_results).to be_empty
    end
  end
end
