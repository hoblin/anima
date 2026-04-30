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

  describe "diagnostic logging" do
    let(:debug_messages) { [] }

    before do
      allow(Aoide.logger).to receive(:info)
      messages = debug_messages
      allow(Aoide.logger).to receive(:debug) do |*args, &block|
        messages << (block ? block.call : args.first)
      end
    end

    it "logs a one-line summary including block and tool_use counts" do
      dispatch({"content" => [
        {"type" => "text", "text" => "thinking"},
        {"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => {}}
      ]})

      expect(Aoide.logger).to have_received(:info)
        .with(/session=#{session.id} — response received \(2 block\(s\), 1 tool_use\)/)
    end

    it "logs the raw response payload as TOON at debug level" do
      response = {"content" => [{"type" => "text", "text" => "hello"}], "stop_reason" => "end_turn"}
      dispatch(response)

      expect(debug_messages).to include(a_string_including("raw response:", Toon.encode(response)))
    end

    it "logs raw tool_use blocks before normalization, preserving missing ids" do
      dispatch({"content" => [
        {"type" => "text", "text" => "thinking"},
        {"type" => "tool_use", "name" => "from_melete_goal", "input" => {"goal" => "x"}}
      ]})

      raw_blocks = debug_messages.find { |m| m.start_with?("session=#{session.id} raw tool_use blocks:") }
      expect(raw_blocks).to include("from_melete_goal")
      expect(raw_blocks).not_to match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)
    end

    it "logs each dispatched tool name and id at info level" do
      dispatch({"content" => [
        {"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => {"command" => "ls"}},
        {"type" => "tool_use", "id" => "toolu_2", "name" => "read", "input" => {"path" => "/tmp"}}
      ]})

      expect(Aoide.logger).to have_received(:info)
        .with(/dispatching tool=bash id=toolu_1/)
      expect(Aoide.logger).to have_received(:info)
        .with(/dispatching tool=read id=toolu_2/)
    end

    it "still logs spurious from_* blocks in the raw payload (filter runs after logging)" do
      dispatch({"content" => [
        {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_zero-width-sleuth", "input" => {}}
      ]})

      raw_blocks = debug_messages.find { |m| m.start_with?("session=#{session.id} raw tool_use blocks:") }
      expect(raw_blocks).to include("from_zero-width-sleuth")
    end
  end

  describe "phantom (from_*) tool call filtering" do
    it "drops from_*-only responses to a clean end of turn (no dispatch, no failed tool_result)" do
      expect {
        dispatch({"content" => [
          {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_shell-runner", "input" => {"from" => "shell-runner"}}
        ]})
      }.not_to have_enqueued_job(ToolExecutionJob)

      expect(session.messages.where(message_type: "tool_call")).to be_empty
      expect(session.reload.aasm_state).to eq("idle")
    end

    it "dispatches only the legitimate tool calls when a from_* block sits alongside them" do
      expect {
        dispatch({"content" => [
          {"type" => "tool_use", "id" => "toolu_real", "name" => "bash", "input" => {"command" => "ls"}},
          {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_zero-width-sleuth", "input" => {}}
        ]})
      }.to have_enqueued_job(ToolExecutionJob).with(session.id, hash_including(tool_name: "bash"))
        .and(have_enqueued_job(ToolExecutionJob).exactly(1).times)

      tool_calls = session.messages.where(message_type: "tool_call")
      expect(tool_calls.size).to eq(1)
      expect(tool_calls.first.payload["tool_name"]).to eq("bash")
      expect(session.reload.aasm_state).to eq("executing")
    end

    it "keeps the agent's text reply when a from_* block is the only tool call" do
      dispatch({"content" => [
        {"type" => "text", "text" => "Spawning, then waiting for push delivery."},
        {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_melete_goal", "input" => {}}
      ]})

      agent_message = session.messages.find_by(message_type: "agent_message")
      expect(agent_message.payload["content"]).to eq("Spawning, then waiting for push delivery.")
      expect(session.messages.where(message_type: "tool_call")).to be_empty
      expect(session.reload.aasm_state).to eq("idle")
    end
  end
end
