# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::SubagentCompleted do
  subject(:event) do
    described_class.new(
      content: "The tool execution flow works as follows...",
      child_session_id: 42,
      task: "Read lib/agent_loop.rb and summarize the tool execution flow",
      expected_output: "A summary of how tools are dispatched",
      session_id: 1
    )
  end

  it "has type subagent_completed" do
    expect(event.type).to eq("subagent_completed")
  end

  it "stores content (the result)" do
    expect(event.content).to eq("The tool execution flow works as follows...")
  end

  it "stores child_session_id" do
    expect(event.child_session_id).to eq(42)
  end

  it "stores task" do
    expect(event.task).to eq("Read lib/agent_loop.rb and summarize the tool execution flow")
  end

  it "stores expected_output" do
    expect(event.expected_output).to eq("A summary of how tools are dispatched")
  end

  it "stores session_id (parent)" do
    expect(event.session_id).to eq(1)
  end

  describe "#event_name" do
    it "returns namespaced event name" do
      expect(event.event_name).to eq("anima.subagent_completed")
    end
  end

  describe "#to_h" do
    it "includes all sub-agent completion fields" do
      hash = event.to_h
      expect(hash).to include(
        type: "subagent_completed",
        content: "The tool execution flow works as follows...",
        child_session_id: 42,
        task: "Read lib/agent_loop.rb and summarize the tool execution flow",
        expected_output: "A summary of how tools are dispatched",
        session_id: 1
      )
    end

    it "includes a timestamp" do
      expect(event.to_h[:timestamp]).to be_a(Integer)
    end
  end
end
