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
    # Stub the analytical brain to simulate nickname assignment
    allow_any_instance_of(AnalyticalBrain::Runner).to receive(:call) do |runner|
      session = runner.instance_variable_get(:@session)
      session.update!(name: "code-scout")
    end

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
      allow(Agents::Registry).to receive(:instance).and_return(agent_registry)
      expect(described_class.description).to include("Available specialists")
      expect(described_class.description).to include("analyzer")
    end

    it "returns base description when no agents are registered" do
      allow(Agents::Registry).to receive(:instance).and_return(Agents::Registry.new)
      expect(described_class.description).not_to include("Available specialists")
    end
  end

  describe ".input_schema" do
    before { allow(Agents::Registry).to receive(:instance).and_return(agent_registry) }

    it "requires name and task" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:name][:type]).to eq("string")
      expect(schema[:properties][:task][:type]).to eq("string")
      expect(schema[:properties]).not_to have_key(:expected_output)
      expect(schema[:required]).to contain_exactly("name", "task")
    end

    it "does not include a tools property" do
      schema = described_class.input_schema
      expect(schema[:properties]).not_to have_key(:tools)
    end

    it "includes name enum when agents are registered" do
      schema = described_class.input_schema
      expect(schema[:properties][:name][:enum]).to contain_exactly("analyzer")
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
        "task" => "Read lib/agent_loop.rb and summarize the tool execution flow"
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

    it "appends the communication instruction to the prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to include("sub-agent collaborating with a parent")
    end

    it "does not append an expected deliverable to the prompt" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).not_to include("Expected deliverable")
    end

    it "assigns nickname via the analytical brain" do
      tool.execute(input)

      child = Session.last
      expect(child.name).to eq("code-scout")
    end

    it "broadcasts children update to parent session" do
      allow(ActionCable.server).to receive(:broadcast)

      tool.execute(input)

      expect(ActionCable.server).to have_received(:broadcast).with(
        "session_#{parent_session.id}",
        hash_including("action" => "children_updated", "session_id" => parent_session.id)
      )
    end

    it "sets parent reference on child session" do
      tool.execute(input)

      child = Session.last
      expect(child.parent_session).to eq(parent_session)
    end

    it "creates a Goal on the child session with the task as description" do
      tool.execute(input)

      child = Session.last
      goal = child.goals.first
      expect(goal).to be_present
      expect(goal.description).to eq("Read lib/agent_loop.rb and summarize the tool execution flow")
      expect(goal).to be_active
      expect(goal).to be_root
    end

    it "persists the fork framing message as the child's first user message" do
      tool.execute(input)

      child = Session.last
      user_event = child.messages.find_by(message_type: "user_message")
      expect(user_event).to be_present
      expect(user_event.payload["content"]).to include("parent agent's context")
      expect(user_event.payload["content"]).to include("Your sole task")
    end

    it "does not persist the task text as a user message" do
      tool.execute(input)

      child = Session.last
      contents = child.messages.where(message_type: "user_message").pluck(:payload).map { |p| p["content"] }
      expect(contents).not_to include("Read lib/agent_loop.rb and summarize the tool execution flow")
    end

    it "enqueues AgentRequestJob for the child session" do
      tool.execute(input)

      child = Session.last
      expect(AgentRequestJob).to have_been_enqueued.with(child.id)
    end

    it "returns confirmation including the nickname and @mention hint" do
      result = tool.execute(input)

      expect(result).to include("Specialist @code-scout spawned")
      expect(result).to include("session #{Session.last.id}")
      expect(result).to include("@code-scout")
    end

    it "falls back to agent-N on brain failure" do
      allow_any_instance_of(AnalyticalBrain::Runner).to receive(:call)
        .and_raise(Providers::Anthropic::RateLimitError, "rate limited")

      tool.execute(input)

      child = Session.last
      expect(child.name).to match(/\Aagent-\d+\z/)
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

      it "does not create a child session" do
        expect { tool.execute(input.merge("task" => "  ")) }
          .not_to change(Session, :count)
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
