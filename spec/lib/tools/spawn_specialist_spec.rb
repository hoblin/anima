# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SpawnSpecialist do
  let!(:parent_session) { Session.create! }
  let(:tmp_dir) { Dir.mktmpdir }
  let(:agent_registry) do
    registry = Agents::Registry.new
    registry.load_directory(tmp_dir)
    registry
  end

  subject(:tool) { described_class.new(session: parent_session, agent_registry: agent_registry) }

  before do
    File.write(File.join(tmp_dir, "analyzer.md"), <<~MD)
      ---
      name: analyzer
      description: Analyzes code
      tools: read, bash
      ---

      You are a code analysis specialist. Examine implementation details carefully.
    MD
  end

  after { FileUtils.remove_entry(tmp_dir) }

  describe ".tool_name" do
    it "returns spawn_specialist" do
      expect(described_class.tool_name).to eq("spawn_specialist")
    end
  end

  describe ".description" do
    it "includes available specialists when agents are registered" do
      expect(described_class.description).to include("Available specialists")
    end
  end

  describe ".input_schema" do
    it "requires name, task, and expected_output" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:name][:type]).to eq("string")
      expect(schema[:properties][:task][:type]).to eq("string")
      expect(schema[:properties][:expected_output][:type]).to eq("string")
      expect(schema[:required]).to contain_exactly("name", "task", "expected_output")
    end

    it "does not include a tools property" do
      schema = described_class.input_schema
      expect(schema[:properties]).not_to have_key(:tools)
    end

    it "includes name enum when agents are registered" do
      schema = described_class.input_schema
      expect(schema[:properties][:name][:enum]).to be_a(Array)
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "spawn_specialist", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    let(:input) do
      {
        "name" => "analyzer",
        "task" => "Read lib/agent_loop.rb and summarize the tool execution flow",
        "expected_output" => "A summary of how tools are dispatched"
      }
    end

    it "creates a child session with the agent's predefined tools" do
      tool.execute(input)

      child = Session.last
      expect(child.granted_tools).to eq(%w[read bash])
    end

    it "uses the agent's system prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to include("code analysis specialist")
    end

    it "appends the return_result instruction to the prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to include("call the return_result tool")
    end

    it "appends the expected deliverable to the prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to include("Expected deliverable: A summary of how tools are dispatched")
    end

    it "stores the agent name on the child session" do
      tool.execute(input)

      child = Session.last
      expect(child.name).to eq("analyzer")
    end

    it "sets parent reference on child session" do
      tool.execute(input)

      child = Session.last
      expect(child.parent_session).to eq(parent_session)
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

    it "returns confirmation including the specialist name" do
      result = tool.execute(input)

      expect(result).to include("Specialist 'analyzer' spawned")
      expect(result).to include("session #{Session.last.id}")
    end

    context "with blank name" do
      it "returns error" do
        result = tool.execute(input.merge("name" => "  "))
        expect(result).to eq({error: "Name cannot be blank"})
      end

      it "does not create a child session" do
        expect { tool.execute(input.merge("name" => "  ")) }
          .not_to change(Session, :count)
      end
    end

    context "with blank task" do
      it "returns error" do
        result = tool.execute(input.merge("task" => "  "))
        expect(result).to eq({error: "Task cannot be blank"})
      end
    end

    context "with blank expected_output" do
      it "returns error" do
        result = tool.execute(input.merge("expected_output" => "  "))
        expect(result).to eq({error: "Expected output cannot be blank"})
      end
    end

    context "with unknown agent name" do
      it "returns error" do
        result = tool.execute(input.merge("name" => "nonexistent"))
        expect(result).to eq({error: "Unknown agent: nonexistent"})
      end

      it "does not create a child session" do
        expect { tool.execute(input.merge("name" => "nonexistent")) }
          .not_to change(Session, :count)
      end
    end
  end
end
