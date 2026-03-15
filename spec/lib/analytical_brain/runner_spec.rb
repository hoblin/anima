# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Runner do
  let(:session) { Session.create! }
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }
  let(:client) { instance_double(LLM::Client) }
  let(:runner) { described_class.new(session, client: client) }

  before do
    allow(Rails.application.credentials).to receive(:dig)
      .with(:anthropic, :subscription_token)
      .and_return(valid_token)
  end

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
        session.events.create!(event_type: "user_message", payload: {"content" => "Tell me about Ruby"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Ruby is great!"}, timestamp: 2)
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

        expect(captured_opts[:system]).to match(/analytical brain/i)
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

        expect(captured_opts[:system]).to include("Available skills")
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

        expect(captured_opts[:system]).to include("Currently active skills")
        expect(captured_opts[:system]).to include("gh-issue")
      end

      it "shows 'None' for active skills when none are active" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Currently active skills\nNone")
      end

      it "registers all analytical brain tools" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        expect(captured_registry.registered?("rename_session")).to be true
        expect(captured_registry.registered?("activate_skill")).to be true
        expect(captured_registry.registered?("deactivate_skill")).to be true
        expect(captured_registry.registered?("set_goal")).to be true
        expect(captured_registry.registered?("finish_goal")).to be true
        expect(captured_registry.registered?("everything_is_ready")).to be true
      end

      it "includes goal tracking responsibilities in system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Goal tracking")
        expect(captured_opts[:system]).to include("Set goals when")
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

        expect(captured_opts[:system]).to include("Active goals")
        expect(captured_opts[:system]).to include("Implement feature X")
        expect(captured_opts[:system]).to include("Read code")
        expect(captured_opts[:system]).to include("Write tests")
      end

      it "omits goals section when no active goals exist" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).not_to include("Active goals")
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

      it "mentions goal management in the user message" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        expect(captured_messages.first[:content]).to include("manage goals")
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
        session.events.create!(event_type: "user_message", payload: {"content" => "Run ls"}, timestamp: 1)
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling bash", "tool_name" => "bash",
                    "tool_input" => {"command" => "ls"}, "tool_use_id" => "t1"},
          timestamp: 2
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "file1.rb\nfile2.rb", "tool_name" => "bash", "tool_use_id" => "t1"},
          timestamp: 3
        )
        session.events.create!(event_type: "agent_message", payload: {"content" => "Here are the files."}, timestamp: 4)
      end

      it "includes tool events in the transcript" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("Tool call: bash")
        expect(content).to include("Tool result:")
        expect(content).to include("file1.rb")
      end
    end

    context "context limiting" do
      it "limits to the configured event window" do
        25.times do |i|
          type = i.even? ? "user_message" : "agent_message"
          session.events.create!(event_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
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
          session.events.create!(event_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
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

    context "event non-persistence" do
      it "does not create Event records during execution" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Hi"}, timestamp: 2)

        # Use a real client with webmock to verify no events are persisted
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: {
              content: [{type: "text", text: "All good"}],
              stop_reason: "end_turn"
            }.to_json,
            headers: {"content-type" => "application/json"}
          )

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)

        expect { real_runner.call }.not_to change(Event, :count)
      end
    end

    context "integration with rename_session tool" do
      it "renames the session when LLM calls rename_session" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Tell me about Ruby"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Ruby is great!"}, timestamp: 2)

        # First call: LLM requests rename_session tool
        # Second call: LLM responds with text after tool result
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count == 1
              {
                status: 200,
                body: {
                  content: [{
                    type: "tool_use",
                    id: "toolu_rename_1",
                    name: "rename_session",
                    input: {"emoji" => "💎", "name" => "Ruby Basics"}
                  }],
                  stop_reason: "tool_use"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            else
              {
                status: 200,
                body: {
                  content: [{type: "text", text: "Done"}],
                  stop_reason: "end_turn"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            end
          end

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)
        real_runner.call

        expect(session.reload.name).to eq("💎 Ruby Basics")
      end
    end

    context "integration with activate_skill tool" do
      before { Skills::Registry.reload! }

      it "activates a skill when LLM calls activate_skill" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Create a GitHub issue"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Sure!"}, timestamp: 2)

        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count == 1
              {
                status: 200,
                body: {
                  content: [{
                    type: "tool_use",
                    id: "toolu_activate_1",
                    name: "activate_skill",
                    input: {"name" => "gh-issue"}
                  }],
                  stop_reason: "tool_use"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            else
              {
                status: 200,
                body: {
                  content: [{type: "text", text: "Done"}],
                  stop_reason: "end_turn"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            end
          end

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)
        real_runner.call

        expect(session.reload.active_skills).to include("gh-issue")
      end
    end

    context "integration with deactivate_skill tool" do
      before { Skills::Registry.reload! }

      it "deactivates a skill when LLM calls deactivate_skill" do
        session.activate_skill("gh-issue")
        session.events.create!(event_type: "user_message", payload: {"content" => "We're done with issues"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "OK"}, timestamp: 2)

        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count == 1
              {
                status: 200,
                body: {
                  content: [{
                    type: "tool_use",
                    id: "toolu_deactivate_1",
                    name: "deactivate_skill",
                    input: {"name" => "gh-issue"}
                  }],
                  stop_reason: "tool_use"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            else
              {
                status: 200,
                body: {
                  content: [{type: "text", text: "Done"}],
                  stop_reason: "end_turn"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            end
          end

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)
        real_runner.call

        expect(session.reload.active_skills).not_to include("gh-issue")
      end
    end

    context "integration with set_goal tool" do
      it "creates a goal when LLM calls set_goal" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Implement auth refactoring"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Sure!"}, timestamp: 2)

        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count == 1
              {
                status: 200,
                body: {
                  content: [{
                    type: "tool_use",
                    id: "toolu_set_goal_1",
                    name: "set_goal",
                    input: {"description" => "Implement auth refactoring"}
                  }],
                  stop_reason: "tool_use"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            else
              {
                status: 200,
                body: {
                  content: [{type: "text", text: "Done"}],
                  stop_reason: "end_turn"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            end
          end

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)
        real_runner.call

        expect(session.goals.count).to eq(1)
        goal = session.goals.first
        expect(goal.description).to eq("Implement auth refactoring")
        expect(goal.status).to eq("active")
      end
    end

    context "integration with finish_goal tool" do
      it "completes a goal when LLM calls finish_goal" do
        goal = session.goals.create!(description: "Read code")
        session.events.create!(event_type: "user_message", payload: {"content" => "Done reading"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "OK"}, timestamp: 2)

        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count == 1
              {
                status: 200,
                body: {
                  content: [{
                    type: "tool_use",
                    id: "toolu_finish_goal_1",
                    name: "finish_goal",
                    input: {"goal_id" => goal.id}
                  }],
                  stop_reason: "tool_use"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            else
              {
                status: 200,
                body: {
                  content: [{type: "text", text: "Done"}],
                  stop_reason: "end_turn"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            end
          end

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)
        real_runner.call

        expect(goal.reload.status).to eq("completed")
        expect(goal.completed_at).to be_present
      end
    end

    context "integration with everything_is_ready tool" do
      it "completes without changing session name" do
        session.update!(name: "🔧 Existing Name")
        session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Hi there"}, timestamp: 2)

        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count == 1
              {
                status: 200,
                body: {
                  content: [{
                    type: "tool_use",
                    id: "toolu_ready_1",
                    name: "everything_is_ready",
                    input: {}
                  }],
                  stop_reason: "tool_use"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            else
              {
                status: 200,
                body: {
                  content: [{type: "text", text: "All good"}],
                  stop_reason: "end_turn"
                }.to_json,
                headers: {"content-type" => "application/json"}
              }
            end
          end

        real_client = LLM::Client.new(model: Anima::Settings.fast_model, max_tokens: 128)
        real_runner = described_class.new(session, client: real_client)
        real_runner.call

        expect(session.reload.name).to eq("🔧 Existing Name")
      end
    end
  end

  describe "default client configuration" do
    it "uses the fast model" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Test"}, timestamp: 1)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(body: hash_including("model" => Anima::Settings.fast_model))
        .to_return(
          status: 200,
          body: {content: [{type: "text", text: "ok"}], stop_reason: "end_turn"}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.new(session).call

      expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages")
        .with(body: hash_including("model" => Anima::Settings.fast_model))
    end
  end
end
