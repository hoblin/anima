# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::PassiveRecall do
  let(:session) { Session.create! }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:recall_budget_fraction).and_return(0.05)
    allow(Anima::Settings).to receive(:recall_max_results).and_return(5)
    allow(Anima::Settings).to receive(:recall_max_snippet_tokens).and_return(512)
    allow(Anima::Settings).to receive(:recall_relevance_gate_enabled).and_return(false)
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

    it "does not re-create pending messages for already pending recalls" do
      other_session = Session.create!
      create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      session.goals.create!(description: "Fix the authentication flow")

      described_class.new(session).call
      expect { described_class.new(session).call }
        .not_to change { session.pending_messages.count }
    end

    # Production stores the recalled message_id in `tool_input.message_id` of
    # the promoted `from_mneme` tool_call — not in `tool_use_id`. The filter
    # has to reach into the JSON payload for dedup to work after promotion.
    it "does not recall messages already promoted as from_mneme pairs" do
      other_session = Session.create!
      event = create_message(other_session, type: "user_message",
        content: "The authentication flow needs fixing.")

      session.messages.create!(
        message_type: "tool_call",
        tool_use_id: "from_mneme_999",
        payload: {
          "tool_name" => "from_mneme",
          "tool_use_id" => "from_mneme_999",
          "tool_input" => {"message_id" => event.id},
          "content" => "Recalling"
        },
        timestamp: Time.current.to_ns
      )

      session.goals.create!(description: "Fix the authentication flow")

      expect { described_class.new(session).call }
        .not_to change { session.pending_messages.count }
    end

    it "excludes messages already in the current viewport" do
      event = create_message(session, type: "user_message",
        content: "Authentication is broken")
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: event.id))

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

    context "with the relevance gate enabled" do
      before do
        allow(Anima::Settings).to receive(:recall_relevance_gate_enabled).and_return(true)
      end

      it "only enqueues candidates the gate keeps" do
        other_session = Session.create!
        keeper = create_message(other_session, type: "user_message",
          content: "OAuth authentication flow keeps returning 401 for refresh tokens.")
        dropped = create_message(other_session, type: "user_message",
          content: "The authentication page CSS is off by one pixel.")

        session.goals.create!(description: "Fix authentication OAuth refresh token flow")

        gate = instance_double(Mneme::RelevanceGate)
        expect(Mneme::RelevanceGate).to receive(:new) { |candidates:, **|
          expect(candidates.map(&:message_id)).to contain_exactly(keeper.id, dropped.id)
          allow(gate).to receive(:call).and_return(candidates.select { |c| c.message_id == keeper.id })
          gate
        }

        described_class.new(session).call

        recall_names = session.pending_messages.where(source_type: "recall").pluck(:source_name)
        expect(recall_names).to eq([keeper.id.to_s])
      end

      it "skips the gate when there are no candidates to judge" do
        session.goals.create!(description: "Fix something nobody has ever mentioned")

        expect(Mneme::RelevanceGate).not_to receive(:new)

        described_class.new(session).call
      end
    end
  end
end
