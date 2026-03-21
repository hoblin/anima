# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Runner do
  let(:session) { Session.create! }
  let(:client) { instance_double(LLM::Client) }
  let(:runner) { described_class.new(session, client: client) }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:mneme_viewport_fraction).and_return(0.33)
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
    allow(Anima::Settings).to receive(:fast_model).and_return("claude-haiku-4-5")
  end

  # Helper to create events with predetermined token counts.
  def create_event(type:, content: "msg", token_count: 100, tool_name: nil, tool_input: nil)
    payload = case type
    when "tool_call"
      {"content" => "Calling #{tool_name}", "tool_name" => tool_name,
       "tool_input" => tool_input || {}, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    when "tool_response"
      {"content" => content, "tool_name" => tool_name, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    else
      {"content" => content}
    end

    session.events.create!(
      event_type: type,
      payload: payload,
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
      token_count: token_count
    )
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
        create_event(type: "user_message", content: "Tell me about Ruby")
        create_event(type: "agent_message", content: "Ruby is great!")
        create_event(type: "user_message", content: "More details please")
      end

      it "calls chat_with_tools with compressed viewport" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("EVICTION ZONE")
        expect(content).to include("MIDDLE ZONE")
        expect(content).to include("RECENT ZONE")
        expect(content).to include("User: Tell me about Ruby")
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

      it "includes Mneme's system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Mneme")
        expect(captured_opts[:system]).to include("save_snapshot")
        expect(captured_opts[:system]).to include("everything_ok")
      end

      it "registers save_snapshot and everything_ok tools" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        expect(captured_registry.registered?("save_snapshot")).to be true
        expect(captured_registry.registered?("everything_ok")).to be true
      end

      it "does not register standard tools" do
        captured_registry = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_registry = opts[:registry]
          "Done"
        }

        runner.call

        expect(captured_registry.registered?("bash")).to be false
        expect(captured_registry.registered?("rename_session")).to be false
      end

      it "advances the boundary event after completion" do
        allow(client).to receive(:chat_with_tools) { "Done" }

        runner.call

        expect(session.reload.mneme_boundary_event_id).to be_present
      end

      it "sets the boundary to a conversation-or-think event" do
        create_event(type: "tool_call", tool_name: "bash", token_count: 50)
        create_event(type: "tool_response", tool_name: "bash", content: "output", token_count: 50)

        allow(client).to receive(:chat_with_tools) { "Done" }

        runner.call

        boundary_id = session.reload.mneme_boundary_event_id
        boundary_event = Event.find(boundary_id)
        expect(boundary_event).to be_conversation_or_think
      end

      it "updates snapshot range pointers" do
        allow(client).to receive(:chat_with_tools) { "Done" }

        runner.call

        session.reload
        expect(session.mneme_snapshot_first_event_id).to be_present
        expect(session.mneme_snapshot_last_event_id).to be_present
      end
    end

    context "with active goals" do
      before do
        create_event(type: "user_message", content: "Implement feature")
        create_event(type: "agent_message", content: "Working on it")
        session.goals.create!(description: "Build auth flow")
      end

      it "includes active goals in the context" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("Active Goals")
        expect(content).to include("Build auth flow")
      end
    end

    context "when LLM calls everything_ok (no snapshot needed)" do
      before do
        create_event(type: "user_message", content: "Start")
        create_event(type: "tool_call", tool_name: "bash", token_count: 200)
        create_event(type: "tool_response", tool_name: "bash", content: "ok", token_count: 200)
        create_event(type: "agent_message", content: "Done")
      end

      it "advances boundary without creating a snapshot" do
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          opts[:registry].execute("everything_ok", {})
          "Done"
        }

        runner.call

        expect(Snapshot.count).to eq(0)
        expect(session.reload.mneme_boundary_event_id).to be_present
      end
    end

    context "when viewport contains only tool events" do
      before do
        create_event(type: "tool_call", tool_name: "bash", token_count: 100)
        create_event(type: "tool_response", tool_name: "bash", content: "ok", token_count: 100)
      end

      it "does not advance the boundary (no conversation events)" do
        allow(client).to receive(:chat_with_tools) { "Done" }

        runner.call

        expect(session.reload.mneme_boundary_event_id).to be_nil
      end
    end

    context "with think events as the last conversation event" do
      before do
        create_event(type: "user_message", content: "Fix the bug")
        create_event(type: "tool_call", tool_name: "think",
          tool_input: {"thoughts" => "Let me analyze this"}, token_count: 50)
        create_event(type: "tool_response", tool_name: "think", content: "", token_count: 10)
        create_event(type: "tool_call", tool_name: "bash", token_count: 50)
        create_event(type: "tool_response", tool_name: "bash", content: "ok", token_count: 50)
      end

      it "can set boundary to a think event" do
        allow(client).to receive(:chat_with_tools) { "Done" }

        runner.call

        boundary_event = Event.find(session.reload.mneme_boundary_event_id)
        expect(boundary_event).to be_conversation_or_think
      end
    end

    context "with from_event_id boundary" do
      it "starts viewport from the boundary event" do
        old = create_event(type: "user_message", content: "old message")
        create_event(type: "user_message", content: "new message")
        session.update_column(:mneme_boundary_event_id, old.id)

        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("old message")
        expect(content).to include("new message")
      end
    end
  end
end
