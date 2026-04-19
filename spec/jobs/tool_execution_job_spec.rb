# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolExecutionJob do
  let(:session) { Session.create! }
  let(:registry) { instance_double(Tools::Registry, execute: "ok", truncation_threshold: nil) }
  let(:shell_session) { instance_double(ShellSession, finalize: nil) }

  before do
    allow(Tools::Registry).to receive(:build).and_return(registry)
    allow(ShellSession).to receive(:for_session).and_return(shell_session)
    allow(ToolDecorator).to receive(:call) { |_, result| result }
  end

  describe "#perform" do
    it "discards on missing session" do
      expect {
        described_class.perform_now(-1, tool_use_id: "toolu_1", tool_name: "bash", tool_input: {})
      }.not_to raise_error
    end

    it "emits ToolExecuted with success=true on normal completion" do
      emitted = capture_emissions

      described_class.perform_now(session.id, tool_use_id: "toolu_1", tool_name: "bash", tool_input: {"command" => "ls"})

      event = emitted.find { |e| e.is_a?(Events::ToolExecuted) }
      expect(event).to be_present
      expect(event.tool_use_id).to eq("toolu_1")
      expect(event.tool_name).to eq("bash")
      expect(event.content).to eq("ok")
      expect(event.success).to be(true)
    end

    it "emits success=false when the tool returns an error Hash" do
      allow(registry).to receive(:execute).and_return({error: "no such file"})

      emitted = capture_emissions

      described_class.perform_now(session.id, tool_use_id: "toolu_1", tool_name: "read", tool_input: {})

      event = emitted.find { |e| e.is_a?(Events::ToolExecuted) }
      expect(event.success).to be(false)
      expect(event.content).to include("no such file")
    end

    it "emits a synthetic ToolExecuted when the tool raises" do
      allow(registry).to receive(:execute).and_raise(StandardError.new("boom"))

      emitted = capture_emissions

      described_class.perform_now(session.id, tool_use_id: "toolu_1", tool_name: "bash", tool_input: {})

      event = emitted.find { |e| e.is_a?(Events::ToolExecuted) }
      expect(event).to be_present
      expect(event.success).to be(false)
      expect(event.content).to include("boom")
    end

    it "emits a synthetic ToolExecuted when the registry itself blows up" do
      allow(Tools::Registry).to receive(:build).and_raise(RuntimeError.new("registry busted"))

      emitted = capture_emissions

      described_class.perform_now(session.id, tool_use_id: "toolu_1", tool_name: "bash", tool_input: {})

      event = emitted.find { |e| e.is_a?(Events::ToolExecuted) }
      expect(event).to be_present
      expect(event.success).to be(false)
      expect(event.content).to include("registry busted")
    end

    it "finalizes the shell session in the ensure block" do
      described_class.perform_now(session.id, tool_use_id: "toolu_1", tool_name: "bash", tool_input: {})

      expect(shell_session).to have_received(:finalize)
    end

    it "runs the output through ResponseTruncator when a threshold is configured" do
      allow(registry).to receive(:truncation_threshold).and_return(10)
      allow(registry).to receive(:execute).and_return("huge output")
      expect(Tools::ResponseTruncator).to receive(:truncate)
        .with("huge output", hash_including(threshold: 10))
        .and_return("huge output (truncated)")

      described_class.perform_now(session.id, tool_use_id: "toolu_1", tool_name: "bash", tool_input: {})
    end
  end
end
