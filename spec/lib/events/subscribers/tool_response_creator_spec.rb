# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::ToolResponseCreator do
  subject(:creator) { described_class.new }

  let(:session) { Session.create! }

  def dispatch(overrides = {})
    creator.emit(
      name: "anima.session.tool_executed",
      payload: {
        type: "session.tool_executed",
        session_id: session.id,
        tool_use_id: "toolu_1",
        tool_name: "bash",
        content: "drwxr-xr-x\n",
        success: true
      }.merge(overrides)
    )
  end

  describe "#emit" do
    it "creates a tool_response PendingMessage with payload fields" do
      dispatch

      pm = session.pending_messages.last
      expect(pm.message_type).to eq("tool_response")
      expect(pm.kind).to eq("active")
      expect(pm.source_type).to eq("tool")
      expect(pm.source_name).to eq("bash")
      expect(pm.tool_use_id).to eq("toolu_1")
      expect(pm.success).to be(true)
      expect(pm.content).to eq("drwxr-xr-x\n")
    end

    it "records failures as success=false" do
      dispatch(success: false, content: "Errno::ENOENT")

      pm = session.pending_messages.last
      expect(pm.success).to be(false)
      expect(pm.content).to eq("Errno::ENOENT")
    end

    it "never touches session state" do
      session.start_processing!
      session.tool_received! # → :executing

      expect { dispatch }.not_to change { session.reload.aasm_state }
    end

    it "raises when session_id does not exist" do
      expect {
        creator.emit(
          name: "anima.session.tool_executed",
          payload: {session_id: -1, tool_use_id: "t", tool_name: "bash", content: "", success: true}
        )
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
