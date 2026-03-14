# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SpawnSubagent do
  let!(:parent_session) { Session.create! }

  subject(:tool) { described_class.new(session: parent_session) }

  describe ".tool_name" do
    it "returns spawn_subagent" do
      expect(described_class.tool_name).to eq("spawn_subagent")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".input_schema" do
    it "defines task and expected_output as required string properties" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:task][:type]).to eq("string")
      expect(schema[:properties][:expected_output][:type]).to eq("string")
      expect(schema[:required]).to contain_exactly("task", "expected_output")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "spawn_subagent", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    let(:input) do
      {
        "task" => "Read lib/agent_loop.rb and summarize the tool execution flow",
        "expected_output" => "A summary of how tools are dispatched"
      }
    end

    it "creates a child session with parent reference" do
      expect { tool.execute(input) }.to change(Session, :count).by(1)

      child = Session.last
      expect(child.parent_session).to eq(parent_session)
    end

    it "sets the child session's system prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to include("focused sub-agent")
      expect(child.prompt).to include("Expected deliverable: A summary of how tools are dispatched")
    end

    it "emits a user_message event in the child session" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      tool.execute(input)

      user_messages = collector.messages.select { |m| m[:role] == "user" }
      expect(user_messages.last[:content]).to eq("Read lib/agent_loop.rb and summarize the tool execution flow")
    ensure
      Events::Bus.unsubscribe(collector)
    end

    it "enqueues AgentRequestJob for the child session" do
      tool.execute(input)

      child = Session.last
      expect(AgentRequestJob).to have_been_enqueued.with(child.id)
    end

    it "returns confirmation with child session ID" do
      result = tool.execute(input)

      child = Session.last
      expect(result).to include("Sub-agent spawned")
      expect(result).to include("session #{child.id}")
    end

    it "returns immediately (non-blocking)" do
      # Verify the tool returns a string, not an LLM response
      result = tool.execute(input)
      expect(result).to be_a(String)
    end

    context "with blank task" do
      it "returns error" do
        result = tool.execute("task" => "  ", "expected_output" => "something")
        expect(result).to eq({error: "Task cannot be blank"})
      end

      it "does not create a child session" do
        expect { tool.execute("task" => "", "expected_output" => "something") }
          .not_to change(Session, :count)
      end
    end

    context "with blank expected_output" do
      it "returns error" do
        result = tool.execute("task" => "do something", "expected_output" => "  ")
        expect(result).to eq({error: "Expected output cannot be blank"})
      end
    end
  end
end
