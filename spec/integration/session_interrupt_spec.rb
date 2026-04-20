# frozen_string_literal: true

require "rails_helper"

# Integration spec for the session interrupt flow. Verifies that the
# layered pieces compose into a clean round-trip when a running tool
# is interrupted:
#
#   :executing + outstanding tool_call
#     -> interrupt_requested = true              (SessionChannel#interrupt_execution)
#     -> bash cooperatively aborts, emits synthetic tool_response PM
#     -> PM#promote! persists the tool_response Message
#     -> start_processing! (:executing -> :awaiting)  closes the round
#     -> response_complete! (:awaiting -> :idle)      LLM acknowledges
#     -> clear_interrupt_flag_if_idle resets the flag
#
# Individual layers (bash polling, PM promotion, SessionChannel flag
# setting) have dedicated specs. This one stitches them together so
# regressions at the seams surface quickly.
RSpec.describe "Session interrupt flow" do
  let(:session) { create(:session) }
  let(:tool_use_id) { "tu_bash_interrupt_1" }

  before do
    session.start_processing!
    session.tool_received!

    create(:message, :bash_tool_call,
      session: session,
      tool_use_id: tool_use_id,
      payload: {
        "tool_name" => "bash",
        "tool_use_id" => tool_use_id,
        "tool_input" => {"command" => "sleep 10"}
      })

    session.update!(interrupt_requested: true)
  end

  it "drops back to idle and clears the flag once the interrupt round-trip completes" do
    synthetic_response = create(:pending_message, :tool_response,
      session: session,
      tool_use_id: tool_use_id,
      source_name: "bash",
      content: LLM::Client::INTERRUPT_MESSAGE,
      success: false)

    synthetic_response.promote!

    tool_response = session.messages.find_by(message_type: "tool_response", tool_use_id: tool_use_id)
    expect(tool_response.payload["content"]).to eq(LLM::Client::INTERRUPT_MESSAGE)
    expect(tool_response.payload["success"]).to be(false)

    expect(session.start_processing!).to be_truthy
    expect(session).to be_awaiting
    expect(session.reload.interrupt_requested?).to be(true)

    expect(session.response_complete!).to be_truthy
    expect(session).to be_idle
    expect(session.reload.interrupt_requested?).to be(false)
  end
end
