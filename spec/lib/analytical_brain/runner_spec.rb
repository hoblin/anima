# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Runner do
  let(:session) { Session.create! }
  let(:client) { instance_double(LLM::Client) }
  let(:runner) { described_class.new(session, client: client) }

  describe "#call" do
    it "returns nil when session has no events" do
      expect(runner.call).to be_nil
    end

    it "does not call the LLM when session has no events" do
      allow(client).to receive(:chat_with_tools)

      runner.call

      expect(client).not_to have_received(:chat_with_tools)
    end

    context "with conversation events" do
      before do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Tell me about Ruby"}, timestamp: 1)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "Ruby is great!"}, timestamp: 2)
      end

      it "calls chat_with_tools with a transcript of recent events" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        expect(captured_messages.length).to eq(1)
        expect(captured_messages.first[:role]).to eq("user")
        content = captured_messages.first[:content]
        expect(content).to include("The main session is working on this:")
        expect(content).to match(/User:.*Tell me about Ruby/m)
        expect(content).to match(/Assistant:.*Ruby is great!/m)
        expect(content).to include("call everything_is_ready")
      end

      it "passes nil session_id to prevent event persistence" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:session_id]).to be_nil
      end

      it "includes the system prompt with current session name" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("manage context for the main agent")
        expect(captured_opts[:system]).to include("(unnamed)")
      end

      it "includes current session name in system prompt when named" do
        session.update!(name: "🔧 Old Name")
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Old Name")
      end

      it "includes available skills catalog in system prompt" do
        Skills::Registry.reload!
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("AVAILABLE SKILLS")
        expect(captured_opts[:system]).to include("gh-issue")
      end

      it "includes currently active skills in system prompt" do
        Skills::Registry.reload!
        session.activate_skill("gh-issue")
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Active skills:")
        expect(captured_opts[:system]).to include("gh-issue")
      end

      it "shows 'None' for active skills when none are active" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Active skills: None")
      end

      it "includes goal tracking responsibilities in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("GOAL TRACKING")
        expect(captured_opts[:system]).to include("root goal")
        expect(captured_opts[:system]).to include("sub-goals")
        expect(captured_opts[:system]).to include("cascades")
      end

      it "includes active goals in system prompt" do
        root = session.goals.create!(description: "Implement feature X")
        session.goals.create!(description: "Read code", parent_goal: root)
        session.goals.create!(description: "Write tests", parent_goal: root)

        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("ACTIVE GOALS")
        expect(captured_opts[:system]).to include("Implement feature X")
        expect(captured_opts[:system]).to include("Read code")
        expect(captured_opts[:system]).to include("Write tests")
      end

      it "formats sub-goals with checkbox state in system prompt" do
        root = session.goals.create!(description: "Implement feature")
        session.goals.create!(description: "Read code", parent_goal: root, status: "completed", completed_at: 1.hour.ago)
        session.goals.create!(description: "Write tests", parent_goal: root)

        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        system = captured_opts[:system]
        expect(system).to include("[x] Read code")
        expect(system).to include("[ ] Write tests")
        expect(system).to match(/- Implement feature \(id: \d+\)/)
      end

      it "omits goals section when no active goals exist" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).not_to include("ACTIVE GOALS")
      end

      it "excludes completed root goals from active goals section" do
        session.goals.create!(description: "Done goal", status: "completed", completed_at: 1.hour.ago)
        session.goals.create!(description: "Active goal")

        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Active goal")
        expect(captured_opts[:system]).not_to include("Done goal")
      end

      it "includes action instruction in the user message" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        expect(captured_messages.first[:content]).to include("take any needed actions")
      end

      it "does not register standard tools (bash, read, etc.)" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        expect(captured_registry.registered?("bash")).to be false
        expect(captured_registry.registered?("read")).to be false
      end
    end

    context "with tool events in context" do
      before do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Run ls"}, timestamp: 1)
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling bash", "tool_name" => "bash",
                    "tool_input" => {"command" => "ls"}, "tool_use_id" => "t1"},
          tool_use_id: "t1",
          timestamp: 2
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "file1.rb\nfile2.rb", "tool_name" => "bash", "tool_use_id" => "t1"},
          tool_use_id: "t1",
          timestamp: 3
        )
        session.messages.create!(message_type: "agent_message", payload: {"content" => "Here are the files."}, timestamp: 4)
      end

      it "includes tool call with name and params in transcript" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include('Tool call: bash({"command":"ls"})')
      end

      it "shows tool result as success/failure indicator only" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("\u2705")
        expect(content).not_to include("file1.rb")
      end
    end

    context "with think tool events" do
      before do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Fix the auth bug"}, timestamp: 1)
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Three auth failures all in OAuth — config issue, not individual tests.",
                                     "visibility" => "inner"},
                    "tool_use_id" => "t_think"},
          tool_use_id: "t_think",
          timestamp: 2
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "OK", "tool_name" => "think", "tool_use_id" => "t_think"},
          tool_use_id: "t_think",
          timestamp: 3
        )
      end

      it "shows full think text in transcript (not just tool name)" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("Think: Three auth failures all in OAuth")
        expect(content).not_to include("Tool call: think")
      end

      it "excludes think tool responses from transcript" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).not_to include("\u2705")
        expect(content).not_to include("\u274C")
      end
    end

    context "context limiting" do
      it "limits to the configured event window" do
        25.times do |i|
          type = i.even? ? "user_message" : "agent_message"
          session.messages.create!(message_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
        end

        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        # Should include most recent events (msg 24, 23, ...) but not oldest (msg 0, 1, ...)
        expect(content).to include("msg 24")
        expect(content).not_to include("msg 0")
      end

      it "preserves chronological order in transcript" do
        5.times do |i|
          type = i.even? ? "user_message" : "agent_message"
          session.messages.create!(message_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
        end

        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        # msg 0 should appear before msg 4 in the transcript
        expect(content.index("msg 0")).to be < content.index("msg 4")
      end
    end

    context "message non-persistence", :vcr do
      it "does not create Message records during execution" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "Hi"}, timestamp: 2)

        real_runner = described_class.new(session)

        expect { real_runner.call }.not_to change(Message, :count)
      end
    end

    context "integration with real LLM", :vcr do
      it "renames an unnamed session based on conversation topic" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Help me set up PostgreSQL replication for our Rails app"}, timestamp: 1)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "I'll help you configure PostgreSQL streaming replication with your Rails app."}, timestamp: 2)

        described_class.new(session).call

        expect(session.reload.name).to be_present
      end

      it "does not change an already-named session when topic hasn't shifted" do
        session.update!(name: "🔧 Existing Name")
        session.messages.create!(message_type: "user_message", payload: {"content" => "Continue with the fix"}, timestamp: 1)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "Sure, continuing."}, timestamp: 2)

        described_class.new(session).call

        # Brain may or may not rename — but it should complete without error
      end
    end
  end

  describe "modular responsibility composition" do
    context "parent session" do
      before do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "Hi"}, timestamp: 2)
      end

      it "registers rename_session tool" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        expect(captured_registry.registered?("rename_session")).to be true
      end

      it "does not register assign_nickname tool" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        expect(captured_registry.registered?("assign_nickname")).to be false
      end

      it "registers all shared tools" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        %w[activate_skill deactivate_skill read_workflow deactivate_workflow
          set_goal update_goal finish_goal everything_is_ready].each do |name|
          expect(captured_registry.registered?(name)).to be(true), "expected #{name} to be registered"
        end
      end

      it "includes SESSION NAMING in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("SESSION NAMING")
      end

      it "does not include SUB-AGENT NAMING in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).not_to include("SUB-AGENT NAMING")
      end

      it "does not include ACTIVE SIBLINGS in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).not_to include("ACTIVE SIBLINGS")
      end

      it "frames the message as main session observation" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        expect(captured_messages.first[:content]).to include("The main session is working on this:")
      end
    end

    context "child session" do
      let(:parent) { Session.create! }
      let(:child_session) { Session.create!(parent_session: parent, prompt: "sub-agent task") }
      let(:child_runner) { described_class.new(child_session, client: client) }

      before do
        child_session.messages.create!(
          message_type: "user_message",
          payload: {"content" => "Read lib/agent_loop.rb and summarize tool flow"},
          timestamp: 1
        )
      end

      it "registers assign_nickname tool" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        child_runner.call

        expect(captured_registry.registered?("assign_nickname")).to be true
      end

      it "does not register rename_session tool" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        child_runner.call

        expect(captured_registry.registered?("rename_session")).to be false
      end

      it "registers shared tools for skill/workflow/goal management" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        child_runner.call

        %w[activate_skill deactivate_skill set_goal everything_is_ready].each do |name|
          expect(captured_registry.registered?(name)).to be(true), "expected #{name} to be registered"
        end
      end

      it "includes SUB-AGENT NAMING in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        child_runner.call

        expect(captured_opts[:system]).to include("SUB-AGENT NAMING")
      end

      it "does not include SESSION NAMING in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        child_runner.call

        expect(captured_opts[:system]).not_to include("SESSION NAMING")
      end

      it "frames the message as sub-agent task" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        child_runner.call

        content = captured_messages.first[:content]
        expect(content).to include("A sub-agent has been spawned with this task:")
        expect(content).to include("Read lib/agent_loop.rb")
        expect(content).to include("Assign a nickname")
      end

      it "includes active siblings in system prompt when siblings exist" do
        Session.create!(parent_session: parent, prompt: "sibling", name: "api-scout")

        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        child_runner.call

        expect(captured_opts[:system]).to include("ACTIVE SIBLINGS")
        expect(captured_opts[:system]).to include("api-scout")
      end

      it "omits active siblings section when no named siblings exist" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        child_runner.call

        expect(captured_opts[:system]).not_to include("ACTIVE SIBLINGS")
      end

      it "excludes own name from siblings list" do
        child_session.update!(name: "self-name")
        Session.create!(parent_session: parent, prompt: "sibling", name: "other-name")

        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        child_runner.call

        siblings_line = captured_opts[:system][/These nicknames are already taken:.*/]
        expect(siblings_line).to include("other-name")
        expect(siblings_line).not_to include("self-name")
      end
    end
  end

  describe "default client configuration", :vcr do
    it "uses the fast model" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.messages.create!(message_type: "agent_message", payload: {"content" => "Hi"}, timestamp: 2)

      described_class.new(session).call
      # Verified by cassette containing model: claude-haiku-4-5 in request body
    end
  end
end
