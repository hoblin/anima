# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::LLMResponseHandler do
  subject(:handler) { described_class.new }

  let(:session) { Session.create! }

  def dispatch(response, api_metrics: nil)
    handler.emit(
      name: "anima.session.llm_responded",
      payload: {type: "session.llm_responded", session_id: session.id, response: response, api_metrics: api_metrics}
    )
  end

  before { session.start_processing! } # → :awaiting

  describe "#emit" do
    it "persists agent_message and transitions to :idle on a text-only response" do
      dispatch({"content" => [{"type" => "text", "text" => "all done"}], "stop_reason" => "end_turn"})

      expect(session.messages.count).to eq(1)
      msg = session.messages.first
      expect(msg.message_type).to eq("agent_message")
      expect(msg.payload["content"]).to eq("all done")
      expect(session.reload.aasm_state).to eq("idle")
    end

    it "stores api_metrics on the persisted agent_message" do
      dispatch(
        {"content" => [{"type" => "text", "text" => "hi"}]},
        api_metrics: {"input_tokens" => 42}
      )

      expect(session.messages.first.api_metrics).to eq({"input_tokens" => 42})
    end

    it "concatenates multiple text blocks" do
      dispatch({"content" => [
        {"type" => "text", "text" => "first "},
        {"type" => "text", "text" => "second"}
      ]})

      expect(session.messages.first.payload["content"]).to eq("first second")
    end

    it "persists a tool_call message and transitions to :executing for a tool_use response" do
      dispatch({"content" => [
        {"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => {"command" => "ls"}}
      ]})

      call = session.messages.find_by(message_type: "tool_call")
      expect(call.tool_use_id).to eq("toolu_1")
      expect(call.payload["tool_name"]).to eq("bash")
      expect(session.reload.aasm_state).to eq("executing")
    end

    it "dispatches ToolExecutionJob for each tool_use block" do
      expect {
        dispatch({"content" => [
          {"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => {"command" => "ls"}},
          {"type" => "tool_use", "id" => "toolu_2", "name" => "read", "input" => {"path" => "/tmp"}}
        ]})
      }.to have_enqueued_job(ToolExecutionJob).exactly(2).times
    end

    it "persists both text and tool_call when the response carries mixed blocks" do
      dispatch({"content" => [
        {"type" => "text", "text" => "thinking"},
        {"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => {}}
      ]})

      expect(session.messages.where(message_type: "agent_message").count).to eq(1)
      expect(session.messages.where(message_type: "tool_call").count).to eq(1)
      expect(session.reload.aasm_state).to eq("executing")
    end

    it "generates a UUID tool_use_id when the provider omits one" do
      dispatch({"content" => [
        {"type" => "tool_use", "name" => "bash", "input" => {}}
      ]})

      call = session.messages.find_by(message_type: "tool_call")
      expect(call.tool_use_id).to be_present
    end

    it "ignores empty-content responses without transitioning" do
      dispatch({"content" => []})

      expect(session.messages.count).to eq(0)
      expect(session.reload.aasm_state).to eq("idle")
    end
  end
end
