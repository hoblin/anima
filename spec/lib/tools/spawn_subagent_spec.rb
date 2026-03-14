# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SpawnSubagent do
  let!(:parent_session) { Session.create! }
  let(:agent_registry) { Agents::Registry.new }

  subject(:tool) { described_class.new(session: parent_session, agent_registry: agent_registry) }

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

    it "includes available specialists when agents are registered" do
      description = described_class.description

      expect(description).to include("Available specialists")
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

    it "includes name property with enum when agents are registered" do
      schema = described_class.input_schema
      name_prop = schema[:properties][:name]

      expect(name_prop).not_to be_nil
      expect(name_prop[:type]).to eq("string")
      expect(name_prop[:enum]).to be_a(Array)
      expect(name_prop[:enum]).not_to be_empty
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

    context "generic sub-agent (no name)" do
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
        result = tool.execute(input)
        expect(result).to be_a(String)
      end
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

    context "tool restriction (generic)" do
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
        expect(result).to include("Sub-agent spawned")
      end
    end

    context "named sub-agent" do
      let(:tmp_dir) { Dir.mktmpdir }

      let(:agent_registry) do
        registry = Agents::Registry.new
        registry.load_directory(tmp_dir)
        registry
      end

      after { FileUtils.remove_entry(tmp_dir) }

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

      it "creates a child session with the agent's predefined tools" do
        tool.execute(input.merge("name" => "analyzer"))

        child = Session.last
        expect(child.granted_tools).to eq(%w[read bash])
      end

      it "uses the agent's system prompt instead of the generic prompt" do
        tool.execute(input.merge("name" => "analyzer"))

        child = Session.last
        expect(child.prompt).to include("code analysis specialist")
        expect(child.prompt).not_to include("focused sub-agent")
      end

      it "appends the return_result instruction to the agent's prompt" do
        tool.execute(input.merge("name" => "analyzer"))

        child = Session.last
        expect(child.prompt).to include("call the return_result tool")
      end

      it "appends the expected deliverable to the prompt" do
        tool.execute(input.merge("name" => "analyzer"))

        child = Session.last
        expect(child.prompt).to include("Expected deliverable: A summary of how tools are dispatched")
      end

      it "returns confirmation including the agent name" do
        result = tool.execute(input.merge("name" => "analyzer"))

        expect(result).to include("Sub-agent 'analyzer' spawned")
        expect(result).to include("session #{Session.last.id}")
      end

      it "enqueues AgentRequestJob for the child session" do
        tool.execute(input.merge("name" => "analyzer"))

        child = Session.last
        expect(AgentRequestJob).to have_been_enqueued.with(child.id)
      end

      it "ignores the tools parameter when name is provided" do
        tool.execute(input.merge("name" => "analyzer", "tools" => ["web_get", "write"]))

        child = Session.last
        expect(child.granted_tools).to eq(%w[read bash])
      end

      it "returns error for unknown agent names" do
        result = tool.execute(input.merge("name" => "nonexistent"))

        expect(result).to eq({error: "Unknown agent: nonexistent"})
      end

      it "does not create a child session for unknown agent names" do
        expect { tool.execute(input.merge("name" => "nonexistent")) }
          .not_to change(Session, :count)
      end

      it "treats blank name as generic sub-agent" do
        tool.execute(input.merge("name" => "  "))

        child = Session.last
        expect(child.prompt).to include("focused sub-agent")
      end

      context "with invalid tools in agent definition" do
        before do
          File.write(File.join(tmp_dir, "bad-tools.md"), <<~MD)
            ---
            name: bad-tools
            description: Agent with invalid tools
            tools: read, teleport
            ---

            Bad agent prompt.
          MD

          agent_registry.load_directory(tmp_dir)
        end

        it "returns error when agent definition has unknown tools" do
          result = tool.execute(input.merge("name" => "bad-tools"))

          expect(result).to eq({error: "Unknown tool: teleport"})
        end

        it "does not create a child session" do
          expect { tool.execute(input.merge("name" => "bad-tools")) }
            .not_to change(Session, :count)
        end
      end
    end
  end
end
