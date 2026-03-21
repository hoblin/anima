# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SpawnSubagent do
  let!(:parent_session) { Session.create! }

  subject(:tool) { described_class.new(session: parent_session) }

  before do
    # Stub the analytical brain to simulate nickname assignment
    allow_any_instance_of(AnalyticalBrain::Runner).to receive(:call) do |runner|
      session = runner.instance_variable_get(:@session)
      session.update!(name: "loop-sleuth")
    end
  end

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

    it "does not mention specialists" do
      expect(described_class.description).not_to include("specialist")
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

    it "defines tools as an optional array property" do
      schema = described_class.input_schema
      tools_prop = schema[:properties][:tools]

      expect(tools_prop[:type]).to eq("array")
      expect(tools_prop[:items]).to eq({type: "string"})
      expect(schema[:required]).not_to include("tools")
    end

    it "lists valid tool names in the tools description" do
      description = described_class.input_schema[:properties][:tools][:description]

      AgentLoop::STANDARD_TOOLS_BY_NAME.each_key do |name|
        expect(description).to include(name)
      end
    end

    it "does not include a name property" do
      schema = described_class.input_schema
      expect(schema[:properties]).not_to have_key(:name)
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

    it "sets the child session's generic system prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to include("focused sub-agent")
      expect(child.prompt).to include("Expected deliverable: A summary of how tools are dispatched")
    end

    it "persists a user_message event in the child session" do
      tool.execute(input)

      child = Session.last
      user_event = child.events.find_by(event_type: "user_message")
      expect(user_event).to be_present
      expect(user_event.payload["content"]).to eq("Read lib/agent_loop.rb and summarize the tool execution flow")
      expect(user_event.status).to be_nil
    end

    it "enqueues AgentRequestJob for the child session" do
      tool.execute(input)

      child = Session.last
      expect(AgentRequestJob).to have_been_enqueued.with(child.id)
    end

    it "broadcasts children update to parent session" do
      allow(ActionCable.server).to receive(:broadcast)

      tool.execute(input)

      expect(ActionCable.server).to have_received(:broadcast).with(
        "session_#{parent_session.id}",
        hash_including("action" => "children_updated", "session_id" => parent_session.id)
      )
    end

    it "returns confirmation with @nickname and session ID" do
      result = tool.execute(input)

      child = Session.last
      expect(result).to include("Sub-agent @loop-sleuth spawned")
      expect(result).to include("session #{child.id}")
      expect(result).to include("@loop-sleuth")
    end

    it "assigns nickname via the analytical brain" do
      tool.execute(input)

      child = Session.last
      expect(child.name).to eq("loop-sleuth")
    end

    it "runs the analytical brain synchronously" do
      brain_called = false
      allow_any_instance_of(AnalyticalBrain::Runner).to receive(:call) do |runner|
        brain_called = true
        session = runner.instance_variable_get(:@session)
        session.update!(name: "brain-named")
      end

      tool.execute(input)

      expect(brain_called).to be true
      expect(Session.last.name).to eq("brain-named")
    end

    it "propagates brain failures" do
      allow_any_instance_of(AnalyticalBrain::Runner).to receive(:call)
        .and_raise(Providers::Anthropic::RateLimitError, "rate limited")

      expect { tool.execute(input) }.to raise_error(Providers::Anthropic::RateLimitError)
    end

    it "returns immediately (non-blocking)" do
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

    context "tool restriction" do
      it "stores granted_tools as nil when tools parameter is omitted" do
        tool.execute(input)

        child = Session.last
        expect(child.granted_tools).to be_nil
      end

      it "stores granted_tools when tools parameter is provided" do
        tool.execute(input.merge("tools" => ["read", "web_get"]))

        child = Session.last
        expect(child.granted_tools).to eq(["read", "web_get"])
      end

      it "stores empty granted_tools for pure reasoning tasks" do
        tool.execute(input.merge("tools" => []))

        child = Session.last
        expect(child.granted_tools).to eq([])
      end

      it "returns error for unknown tool names" do
        result = tool.execute(input.merge("tools" => ["read", "teleport"]))

        expect(result).to eq({error: "Unknown tool: teleport"})
      end

      it "does not create a child session for unknown tools" do
        expect { tool.execute(input.merge("tools" => ["fake"])) }
          .not_to change(Session, :count)
      end

      it "returns error when tools is not an array (string)" do
        result = tool.execute(input.merge("tools" => "read"))

        expect(result).to eq({error: "tools must be an array"})
      end

      it "returns error when tools is not an array (hash)" do
        result = tool.execute(input.merge("tools" => {"read" => true}))

        expect(result).to eq({error: "tools must be an array"})
      end

      it "normalizes tool names to lowercase" do
        tool.execute(input.merge("tools" => ["Read", "WEB_GET"]))

        child = Session.last
        expect(child.granted_tools).to eq(["read", "web_get"])
      end

      it "deduplicates tool names" do
        tool.execute(input.merge("tools" => ["read", "read", "bash"]))

        child = Session.last
        expect(child.granted_tools).to eq(["read", "bash"])
      end

      it "accepts all valid standard tool names" do
        valid_names = AgentLoop::STANDARD_TOOLS_BY_NAME.keys
        result = tool.execute(input.merge("tools" => valid_names))

        expect(result).to be_a(String)
        expect(result).to include("Sub-agent @loop-sleuth spawned")
      end
    end
  end
end
