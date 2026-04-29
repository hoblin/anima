# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SpawnSubagent do
  let!(:parent_session) { Session.create! }

  subject(:tool) { described_class.new(session: parent_session) }

  before do
    # Stub Melete to simulate nickname assignment
    allow_any_instance_of(Melete::Runner).to receive(:call) do |runner|
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

    it "leads with hook and call-to-action" do
      expect(described_class.description).to include("sidequest")
    end

    it "explains @mention syntax without using @ in the text" do
      expect(described_class.description).to include("Prefix")
      expect(described_class.description).not_to match(/@\w/)
    end
  end

  describe ".input_schema" do
    it "defines task as the only required string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:task][:type]).to eq("string")
      expect(schema[:properties]).not_to have_key(:expected_output)
      expect(schema[:required]).to contain_exactly("task")
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

      Tools::Registry::STANDARD_TOOLS_BY_NAME.each_key do |name|
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
        "task" => "Read lib/agent_loop.rb and summarize the tool execution flow"
      }
    end

    it "creates a child session with parent reference" do
      expect { tool.execute(input) }.to change(Session, :count).by(1)

      child = Session.last
      expect(child.parent_session).to eq(parent_session)
    end

    context "initial_cwd inheritance" do
      # The child's running shell looks up parent cwd via tmux dynamically,
      # but +initial_cwd+ is the persisted fallback used when the parent's
      # tmux session is gone (e.g. across an Anima restart). Snapshotting
      # parent's current cwd at spawn time keeps that fallback useful
      # rather than letting it default to nil → process cwd.
      it "snapshots parent's current tmux cwd as the child's initial_cwd" do
        allow(ShellSession).to receive(:cwd_via_tmux).with(parent_session.id).and_return("/tmp/work")

        tool.execute(input)

        expect(Session.last.initial_cwd).to eq("/tmp/work")
      end

      it "falls back to parent's initial_cwd when parent's tmux session is gone" do
        parent_session.update!(initial_cwd: "/home/agent")
        allow(ShellSession).to receive(:cwd_via_tmux).with(parent_session.id).and_return(nil)

        tool.execute(input)

        expect(Session.last.initial_cwd).to eq("/home/agent")
      end
    end

    it "captures the invoking tool_call's id on the child as spawn_tool_use_id" do
      tool = described_class.new(
        session: parent_session,
        tool_use_id: "toolu_spawn_abc"
      )

      tool.execute(input)

      expect(Session.last.spawn_tool_use_id).to eq("toolu_spawn_abc")
    end

    it "sets the child session's prompt with identity context" do
      tool.execute(input)

      child = Session.last
      expect(child.prompt).to start_with("You are loop-sleuth, a sub-agent")
      expect(child.prompt).to include("messages reach the parent automatically")
      expect(child.prompt).not_to include("Expected deliverable")
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

    it "persists the task as the child's first user message" do
      tool.execute(input)

      child = Session.last
      user_event = child.messages.find_by(message_type: "user_message")
      expect(user_event).to be_present
      expect(user_event.payload["content"]).to eq(input["task"])
    end

    it "auto-pins the task message to the Goal" do
      tool.execute(input)

      child = Session.last
      goal = child.goals.first
      pin = child.pinned_messages.first

      expect(pin).to be_present
      expect(pin.goals).to include(goal)
      expect(pin.message).to eq(child.messages.find_by(message_type: "user_message"))
      expect(pin.display_text).to eq(input["task"].truncate(PinnedMessage::MAX_DISPLAY_TEXT_LENGTH))
    end

    it "kicks the inbound pipeline by enqueueing the task as a user_message PendingMessage" do
      tool.execute(input)

      child = Session.last
      pm = child.pending_messages.find_by(message_type: "user_message")
      expect(pm).to be_present
      expect(pm.content).to eq(input["task"])
      expect(MnemeEnrichmentJob).to have_been_enqueued.with(child.id, pending_message_id: pm.id)
    end

    it "broadcasts children update to parent session" do
      allow(ActionCable.server).to receive(:broadcast)

      tool.execute(input)

      expect(ActionCable.server).to have_received(:broadcast).with(
        "session_#{parent_session.id}",
        hash_including("action" => "children_updated", "session_id" => parent_session.id)
      )
    end

    it "returns confirmation with nickname (no @ prefix) and session ID" do
      result = tool.execute(input)

      child = Session.last
      expect(result).to include("Sub-agent loop-sleuth spawned")
      expect(result).to include("session #{child.id}")
      expect(result).to include("prefix its name with @")
      expect(result).not_to match(/@loop-sleuth/)
    end

    it "assigns nickname via Melete" do
      tool.execute(input)

      child = Session.last
      expect(child.name).to eq("loop-sleuth")
    end

    it "runs Melete synchronously" do
      melete_called = false
      allow_any_instance_of(Melete::Runner).to receive(:call) do |runner|
        melete_called = true
        session = runner.instance_variable_get(:@session)
        session.update!(name: "melete-named")
      end

      tool.execute(input)

      expect(melete_called).to be true
      expect(Session.last.name).to eq("melete-named")
    end

    it "falls back to agent-N on Melete failure and still injects identity" do
      allow_any_instance_of(Melete::Runner).to receive(:call)
        .and_raise(Providers::Anthropic::RateLimitError, "rate limited")

      tool.execute(input)

      child = Session.last
      expect(child.name).to match(/\Aagent-\d+\z/)
      expect(child.prompt).to include("You are #{child.name}, a sub-agent")
    end

    it "returns immediately (non-blocking)" do
      result = tool.execute(input)
      expect(result).to be_a(String)
    end

    context "with blank task" do
      it "returns error" do
        result = tool.execute("task" => "  ")
        expect(result).to eq({error: "Task cannot be blank"})
      end

      it "does not create a child session" do
        expect { tool.execute("task" => "") }
          .not_to change(Session, :count)
      end
    end

    context "tool restriction" do
      it "stores granted_tools as nil when tools parameter is omitted" do
        tool.execute(input)

        child = Session.last
        expect(child.granted_tools).to be_nil
      end

      it "stores granted_tools when tools parameter is provided" do
        tool.execute(input.merge("tools" => ["read_file", "web_get"]))

        child = Session.last
        expect(child.granted_tools).to eq(["read_file", "web_get"])
      end

      it "stores empty granted_tools for pure reasoning tasks" do
        tool.execute(input.merge("tools" => []))

        child = Session.last
        expect(child.granted_tools).to eq([])
      end

      it "returns error for unknown tool names" do
        result = tool.execute(input.merge("tools" => ["read_file", "teleport"]))

        expect(result).to eq({error: "Unknown tool: teleport"})
      end

      it "does not create a child session for unknown tools" do
        expect { tool.execute(input.merge("tools" => ["fake"])) }
          .not_to change(Session, :count)
      end

      it "returns error when tools is not an array (string)" do
        result = tool.execute(input.merge("tools" => "read_file"))

        expect(result).to eq({error: "tools must be an array"})
      end

      it "returns error when tools is not an array (hash)" do
        result = tool.execute(input.merge("tools" => {"read_file" => true}))

        expect(result).to eq({error: "tools must be an array"})
      end

      it "normalizes tool names to lowercase" do
        tool.execute(input.merge("tools" => ["Read_File", "WEB_GET"]))

        child = Session.last
        expect(child.granted_tools).to eq(["read_file", "web_get"])
      end

      it "deduplicates tool names" do
        tool.execute(input.merge("tools" => ["read_file", "read_file", "bash"]))

        child = Session.last
        expect(child.granted_tools).to eq(["read_file", "bash"])
      end

      it "accepts all valid standard tool names" do
        valid_names = Tools::Registry::STANDARD_TOOLS_BY_NAME.keys
        result = tool.execute(input.merge("tools" => valid_names))

        expect(result).to be_a(String)
        expect(result).to include("Sub-agent loop-sleuth spawned")
      end
    end
  end
end
