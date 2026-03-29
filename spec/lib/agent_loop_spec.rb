# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentLoop do
  let(:session) { Session.create! }
  let(:shell_session) { ShellSession.new(session_id: session.id) }
  let(:client) { double("LLM::Client") }
  let(:mcp_manager) { instance_double(Mcp::ClientManager, register_tools: []) }

  subject(:agent_loop) { described_class.new(session: session, shell_session: shell_session, client: client) }

  before { allow(Mcp::ClientManager).to receive(:new).and_return(mcp_manager) }

  after { agent_loop.finalize }

  describe "#initialize" do
    it "stores the session" do
      expect(agent_loop.session).to eq(session)
    end

    it "creates a ShellSession when none provided" do
      loop = described_class.new(session: session, client: client)
      expect(loop).to be_a(described_class)
      loop.finalize
    end
  end

  describe "#run" do
    before do
      allow(client).to receive(:chat_with_tools).and_return("Hello back!")
    end

    it "returns the response text" do
      session.create_user_message("hi")
      expect(agent_loop.run).to eq("Hello back!")
    end

    it "lets errors propagate" do
      allow(client).to receive(:chat_with_tools).and_raise(StandardError, "Connection failed")
      session.create_user_message("hi")

      expect { agent_loop.run }.to raise_error(StandardError, "Connection failed")
    end

    context "multi-turn conversation" do
      let(:persister) { Events::Subscribers::Persister.new(session) }

      before { Events::Bus.subscribe(persister) }
      after { Events::Bus.unsubscribe(persister) }

      it "includes full conversation history in subsequent LLM calls" do
        allow(client).to receive(:chat_with_tools).and_return("First response")
        session.create_user_message("first message")
        agent_loop.run

        received_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_|
          received_messages = msgs.dup
          "Second response"
        }
        session.create_user_message("second message")
        agent_loop.run

        expect(received_messages.length).to eq(3)
        expect(received_messages[0][:role]).to eq("user")
        expect(received_messages[0][:content]).to end_with("first message")
        expect(received_messages[1]).to eq({role: "assistant", content: "First response"})
        expect(received_messages[2][:role]).to eq("user")
        expect(received_messages[2][:content]).to end_with("second message")
      end
    end
  end

  describe "#run" do
    before do
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools).and_return("Hello back!")
    end

    it "runs the LLM tool-use loop on persisted session messages" do
      received_messages = nil
      allow(client).to receive(:chat_with_tools) { |msgs, **_|
        received_messages = msgs.dup
        "response"
      }

      agent_loop.run

      expect(received_messages.first[:role]).to eq("user")
      expect(received_messages.first[:content]).to end_with("hi")
    end

    it "emits an agent_message event with the response" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.run

      expect(collector.messages.last).to eq({role: "assistant", content: "Hello back!"})
      Events::Bus.unsubscribe(collector)
    end

    it "returns the response text" do
      expect(agent_loop.run).to eq("Hello back!")
    end

    it "does not emit a user_message event" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.run

      user_messages = collector.messages.select { |m| m[:role] == "user" }
      expect(user_messages).to be_empty
      Events::Bus.unsubscribe(collector)
    end

    context "when interrupted by user" do
      before do
        session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
        allow(client).to receive(:chat_with_tools).and_return(nil)
      end

      it "returns nil without emitting an agent message" do
        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        result = agent_loop.run

        expect(result).to be_nil
        agent_messages = collector.messages.select { |m| m[:role] == "assistant" }
        expect(agent_messages).to be_empty
        Events::Bus.unsubscribe(collector)
      end
    end

    context "transient errors propagate for retry logic" do
      it "raises TransientError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::TransientError, "Connection reset by peer")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::TransientError)
      end

      it "raises RateLimitError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::RateLimitError, "Rate limit exceeded")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::RateLimitError)
      end

      it "raises ServerError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::ServerError, "Anthropic server error")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::ServerError)
      end
    end

    context "authentication errors propagate" do
      it "raises AuthenticationError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::AuthenticationError, "Invalid API key")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::AuthenticationError)
      end
    end

    it "passes the tool registry to the LLM client" do
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry).to be_a(Tools::Registry)
        expect(registry.registered?("bash")).to be true
        expect(registry.registered?("web_get")).to be true
        "ok"
      end

      agent_loop.run
    end

    it "passes the session_id to the LLM client" do
      allow(client).to receive(:chat_with_tools) do |_msgs, session_id:, **_|
        expect(session_id).to eq(session.id)
        "ok"
      end

      agent_loop.run
    end
  end

  describe "#finalize" do
    it "finalizes the shell session" do
      mock_shell = instance_double(ShellSession)
      allow(mock_shell).to receive(:finalize)

      loop = described_class.new(session: session, shell_session: mock_shell, client: client)
      loop.finalize

      expect(mock_shell).to have_received(:finalize)
    end

    it "is safe to call multiple times" do
      mock_shell = instance_double(ShellSession)
      allow(mock_shell).to receive(:finalize)

      loop = described_class.new(session: session, shell_session: mock_shell, client: client)
      loop.finalize
      expect { loop.finalize }.not_to raise_error
    end
  end

  describe "tool registry switching" do
    it "registers spawn_subagent, spawn_specialist, and request_feature for main sessions" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry.registered?("spawn_subagent")).to be true
        expect(registry.registered?("spawn_specialist")).to be true
        expect(registry.registered?("open_issue")).to be true
        "ok"
      end

      agent_loop.run
    end

    it "registers mark_goal_completed and no spawning/feature tools for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "sub-agent prompt")
      child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

      sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry.registered?("mark_goal_completed")).to be true
        expect(registry.registered?("spawn_subagent")).to be false
        expect(registry.registered?("spawn_specialist")).to be false
        expect(registry.registered?("open_issue")).to be false
        "done"
      end

      sub_loop.run
      sub_loop.finalize
    end

    context "with tool restriction" do
      it "registers only granted tools plus always-granted tools for restricted sub-agents" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "reader agent", granted_tools: ["read", "web_get"])
        child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

        sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
        allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
          expect(registry.registered?("read")).to be true
          expect(registry.registered?("web_get")).to be true
          expect(registry.registered?("think")).to be true
          expect(registry.registered?("bash")).to be false
          expect(registry.registered?("write")).to be false
          expect(registry.registered?("edit")).to be false
          "done"
        end

        sub_loop.run
        sub_loop.finalize
      end

      it "registers only always-granted tools for empty tools array (pure reasoning)" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "thinker agent", granted_tools: [])
        child.messages.create!(message_type: "user_message", payload: {"content" => "think"}, timestamp: 1)

        sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
        allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
          always_granted = AgentLoop::ALWAYS_GRANTED_TOOLS.map(&:tool_name)
          AgentLoop::STANDARD_TOOLS_BY_NAME.each_key do |name|
            if always_granted.include?(name)
              expect(registry.registered?(name)).to be(true), "expected #{name} to be registered (always granted)"
            else
              expect(registry.registered?(name)).to be(false), "expected #{name} not to be registered"
            end
          end
          "done"
        end

        sub_loop.run
        sub_loop.finalize
      end

      it "registers all standard tools when granted_tools is nil" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "full agent")
        child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

        sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
        allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
          AgentLoop::STANDARD_TOOLS_BY_NAME.each_key do |name|
            expect(registry.registered?(name)).to be true
          end
          "done"
        end

        sub_loop.run
        sub_loop.finalize
      end
    end
  end

  describe "system prompt" do
    it "passes system_prompt to the LLM client for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research agent.")
      child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

      sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
      allow(client).to receive(:chat_with_tools) do |_msgs, system:, **_|
        expect(system).to eq("You are a research agent.")
        "done"
      end

      sub_loop.run
      sub_loop.finalize
    end

    it "passes soul as system prompt for main sessions" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools) do |_msgs, system:, **_|
        expect(system).to include("# Soul")
        "ok"
      end

      agent_loop.run
    end

    it "broadcasts debug context with system prompt and tools in debug mode" do
      session.update!(view_mode: "debug")
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools).and_return("ok")

      expect {
        agent_loop.run
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "id" => Message::SYSTEM_PROMPT_ID,
          "type" => "system_prompt",
          "rendered" => {"debug" => a_hash_including(
            "tools" => a_collection_including(
              a_hash_including(name: "bash"),
              a_hash_including(name: "read"),
              a_hash_including(name: "spawn_subagent")
            )
          )}
        ))
    end

    it "does not broadcast debug context in basic mode" do
      session.update!(view_mode: "basic")
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools).and_return("ok")

      expect {
        agent_loop.run
      }.not_to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("type" => "system_prompt"))
    end
  end

  describe "registry injection" do
    it "accepts a custom registry" do
      registry = Tools::Registry.new(context: {shell_session: shell_session})
      registry.register(Tools::WebGet)

      session.messages.create!(message_type: "user_message", payload: {"content" => "test"}, timestamp: 1)
      loop = described_class.new(session: session, shell_session: shell_session, client: client, registry: registry)
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry.registered?("web_get")).to be true
        expect(registry.registered?("bash")).to be false
        "ok"
      end

      loop.run
      loop.finalize
    end
  end

  describe "MCP tool registration" do
    it "calls Mcp::ClientManager to register MCP tools" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools).and_return("ok")

      agent_loop.run

      expect(mcp_manager).to have_received(:register_tools).with(a_kind_of(Tools::Registry))
    end

    it "emits system messages for MCP servers that failed to load" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools).and_return("ok")
      allow(mcp_manager).to receive(:register_tools)
        .and_return(["MCP: failed to load tools from broken: Connection refused"])

      events = []
      subscriber = double("sub")
      allow(subscriber).to receive(:emit) { |e| events << e }
      Events::Bus.subscribe(subscriber)

      agent_loop.run

      system_msgs = events.select { |e| e[:payload][:type] == "system_message" }
      expect(system_msgs.size).to eq(1)
      expect(system_msgs.first[:payload][:content]).to include("broken")
    ensure
      Events::Bus.unsubscribe(subscriber)
    end

    it "registers MCP tools for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "sub-agent")
      child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

      sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
      allow(client).to receive(:chat_with_tools).and_return("done")

      sub_loop.run

      expect(mcp_manager).to have_received(:register_tools)
      sub_loop.finalize
    end
  end

  describe "integration smoke test", :vcr do
    around { |example| freeze_time(Time.utc(2026, 3, 29, 12, 30, 0)) { example.run } }

    before do
      allow(Tools::ResponseTruncator).to receive(:save_full_output).and_wrap_original do |_method, content|
        path = "/tmp/tool_result_stable.txt"
        File.write(path, content)
        path
      end
    end

    it "processes a message with the full production tool set and system prompt" do
      session.create_user_message("What is the latest issue on hoblin/anima repo?")
      loop = described_class.new(session: session)
      result = loop.run
      loop.finalize

      expect(result).to be_a(String)
      expect(result).to include("hoblin/anima")
    end
  end
end
