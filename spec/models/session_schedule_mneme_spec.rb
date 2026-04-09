# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session, "#schedule_mneme!" do
  subject(:schedule!) { session.schedule_mneme! }

  let(:session) { create(:session) }

  context "when session has no boundary" do
    it "initializes the boundary to the first conversation message" do
      msg = create(:message, :user_message, session:)

      expect { schedule! }
        .to change { session.reload.mneme_boundary_message_id }.from(nil).to(msg.id)
    end

    it "skips non-conversation tool_calls when finding the first boundary" do
      create(:message, :bash_tool_call, session:)
      user_msg = create(:message, :user_message, session:)

      expect { schedule! }
        .to change { session.reload.mneme_boundary_message_id }.from(nil).to(user_msg.id)
    end

    it "accepts a think tool_call as boundary" do
      think = create(:message, :think_tool_call, session:)

      expect { schedule! }
        .to change { session.reload.mneme_boundary_message_id }.from(nil).to(think.id)
    end

    it "does not enqueue MnemeJob on initialization" do
      create(:message, :user_message, session:)

      expect { schedule! }.not_to have_enqueued_job(MnemeJob)
    end

    it "does not change boundary when there are no eligible messages" do
      expect { schedule! }
        .not_to change { session.reload.mneme_boundary_message_id }.from(nil)
    end
  end

  context "when tokens since the boundary fit within the budget" do
    let!(:boundary_msg) { create(:message, :user_message, session:, token_count: 10) }

    before do
      session.update_column(:mneme_boundary_message_id, boundary_msg.id)
      allow(session).to receive(:effective_token_budget).and_return(1000)
    end

    it "does not enqueue MnemeJob" do
      expect { schedule! }.not_to have_enqueued_job(MnemeJob)
    end
  end

  context "when tokens since the boundary exceed the budget" do
    let!(:boundary_msg) { create(:message, :user_message, session:, token_count: 600) }
    let!(:newer_msg) { create(:message, :user_message, session:, token_count: 600) }

    before do
      session.update_column(:mneme_boundary_message_id, boundary_msg.id)
      allow(session).to receive(:effective_token_budget).and_return(1000)
    end

    it "enqueues MnemeJob" do
      expect { schedule! }.to have_enqueued_job(MnemeJob).with(session.id)
    end
  end

  context "for sub-agent sessions" do
    it "does not schedule Mneme" do
      parent = create(:session)
      child = create(:session, parent_session: parent)
      create(:message, :user_message, session: child)

      expect { child.schedule_mneme! }.not_to have_enqueued_job(MnemeJob)
    end
  end
end
