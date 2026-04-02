# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::PassiveRecall do
  let(:session) { Session.create! }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:recall_budget_fraction).and_return(0.05)
    allow(Anima::Settings).to receive(:recall_max_results).and_return(5)
    allow(Anima::Settings).to receive(:recall_max_snippet_tokens).and_return(512)
  end

  def create_message(sess, type:, content:)
    sess.messages.create!(
      message_type: type,
      payload: {"content" => content},
      timestamp: Time.current.to_ns
    )
  end

  describe "#call" do
    it "returns 0 when no active goals" do
      expect(described_class.new(session).call).to eq(0)
    end

    it "returns 0 when goals exist but no matching messages" do
      session.goals.create!(description: "Implement quantum teleportation")

      expect(described_class.new(session).call).to eq(0)
    end

    it "creates pending messages for matching results" do
      other_session = Session.create!
      create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      session.goals.create!(description: "Fix the authentication flow")

      expect { described_class.new(session).call }
        .to change { session.pending_messages.where(source_type: "recall").count }.by(1)
    end

    it "stores recalled message ID as source_name" do
      other_session = Session.create!
      event = create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      session.goals.create!(description: "Fix the authentication flow")
      described_class.new(session).call

      pm = session.pending_messages.find_by(source_type: "recall")
      expect(pm.source_name).to eq(event.id.to_s)
    end

    it "does not re-create pending messages for already recalled messages" do
      other_session = Session.create!
      create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      session.goals.create!(description: "Fix the authentication flow")

      described_class.new(session).call
      expect { described_class.new(session).call }
        .not_to change { session.pending_messages.count }
    end

    it "does not recall messages already promoted to tool pairs" do
      other_session = Session.create!
      event = create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      # Simulate an already-promoted recall
      session.messages.create!(
        message_type: "tool_call",
        tool_use_id: "recall_#{event.id}",
        payload: {"tool_name" => "recall_memory", "tool_use_id" => "recall_#{event.id}",
                  "tool_input" => {}, "content" => "Recalling"},
        timestamp: Time.current.to_ns
      )

      session.goals.create!(description: "Fix the authentication flow")

      expect { described_class.new(session).call }
        .not_to change { session.pending_messages.count }
    end

    it "excludes messages already in the current viewport" do
      event = create_message(session, type: "user_message",
        content: "Authentication is broken")
      session.update_column(:viewport_message_ids, [event.id])

      session.goals.create!(description: "Fix authentication")
      described_class.new(session).call

      recall_names = session.pending_messages.where(source_type: "recall").pluck(:source_name)
      expect(recall_names).not_to include(event.id.to_s)
    end

    it "includes sub-goal descriptions in search terms" do
      other_session = Session.create!
      event = create_message(other_session, type: "user_message",
        content: "The OAuth token refresh logic is wrong.")

      root = session.goals.create!(description: "Fix authentication")
      root.sub_goals.create!(session: session, description: "Fix OAuth token refresh")

      described_class.new(session).call

      recall_names = session.pending_messages.where(source_type: "recall").pluck(:source_name)
      expect(recall_names).to include(event.id.to_s)
    end

    it "ignores completed sub-goals" do
      other_session = Session.create!
      create_message(other_session, type: "user_message",
        content: "The PKCE implementation details.")

      root = session.goals.create!(description: "Fix auth")
      root.sub_goals.create!(session: session, description: "Check PKCE implementation",
        status: "completed", completed_at: Time.current)

      described_class.new(session).call

      recall_pending = session.pending_messages.where(source_type: "recall")
      pkce_recalls = recall_pending.select { |pm|
        msg = Message.find_by(id: pm.source_name.to_i)
        msg&.payload&.dig("content")&.include?("PKCE")
      }
      expect(pkce_recalls).to be_empty
    end
  end
end
