# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Runner do
  subject(:runner) { described_class.new(session, client:) }

  let(:session) { create(:session) }
  let(:client) { instance_double(LLM::Client) }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:eviction_fraction).and_return(0.33)
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
    allow(Anima::Settings).to receive(:fast_model).and_return("claude-haiku-4-5")
  end

  describe "#call" do
    context "with conversation messages" do
      let!(:first) { create(:message, :user_message, session:, payload: {"content" => "Tell me about Ruby"}) }
      let!(:second) { create(:message, :user_message, session:, payload: {"content" => "Ruby is great!"}) }
      let!(:third) { create(:message, :user_message, session:, payload: {"content" => "More details please"}) }

      before { session.update_column(:mneme_boundary_message_id, first.id) }

      it "sends eviction zone and context to the LLM" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("EVICTION ZONE")
        expect(content).to include("CONTEXT")
        expect(content).to include("Tell me about Ruby")
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
      end

      it "sets snapshot range to the eviction zone" do
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          opts[:registry].execute("save_snapshot", {"text" => "Summary"})
          "Done"
        }

        runner.call

        snapshot = Snapshot.last
        expect(snapshot.from_message_id).to eq(first.id)
      end

      it "advances the boundary after completion" do
        allow(client).to receive(:chat_with_tools) { "Done" }

        expect { runner.call }
          .to change { session.reload.mneme_boundary_message_id }
      end
    end

    context "when boundary advances past eviction zone" do
      it "lands on the first conversation message after the zone" do
        # Budget 190K, eviction_fraction 0.33 → eviction budget ~62K
        # 5 messages at 12K each = 60K fits in eviction zone
        # 6th message is beyond the zone
        msgs = 6.times.map { create(:message, :user_message, session:, token_count: 12_000) }
        session.update_column(:mneme_boundary_message_id, msgs.first.id)

        allow(client).to receive(:chat_with_tools) { "Done" }
        runner.call

        # Boundary should advance past the 5 messages that fit, landing on the 6th
        expect(session.reload.mneme_boundary_message_id).to eq(msgs.last.id)
      end

      it "falls back to last eviction message when no messages exist beyond" do
        first = create(:message, :user_message, session:)
        create(:message, :user_message, session:)
        session.update_column(:mneme_boundary_message_id, first.id)

        allow(client).to receive(:chat_with_tools) { "Done" }
        runner.call

        boundary = Message.find(session.reload.mneme_boundary_message_id)
        expect(boundary).to be_conversation_or_think
      end

      it "skips non-conversation tool calls when finding the next boundary" do
        first = create(:message, :user_message, session:, token_count: 100)
        session.update_column(:mneme_boundary_message_id, first.id)
        create(:message, :bash_tool_call, session:, token_count: 100)
        create(:message, :bash_tool_response, session:, token_count: 100)
        conv = create(:message, :user_message, session:, token_count: 100)

        allow(client).to receive(:chat_with_tools) { "Done" }
        runner.call

        expect(session.reload.mneme_boundary_message_id).to eq(conv.id)
      end
    end

    context "with active goals" do
      let!(:msg) { create(:message, :user_message, session:, payload: {"content" => "Implement feature"}) }

      before do
        session.update_column(:mneme_boundary_message_id, msg.id)
        session.goals.create!(description: "Build auth flow")
      end

      it "includes active goals in the LLM context" do
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

    context "when LLM calls everything_ok" do
      let!(:msg) { create(:message, :user_message, session:) }

      before { session.update_column(:mneme_boundary_message_id, msg.id) }

      it "advances boundary without creating a snapshot" do
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          opts[:registry].execute("everything_ok", {})
          "Done"
        }

        runner.call

        expect(Snapshot.count).to eq(0)
        expect(session.reload.mneme_boundary_message_id).to be_present
      end
    end

    context "with tool calls in the eviction zone" do
      let!(:user_msg) { create(:message, :user_message, session:, payload: {"content" => "Fix the bug"}) }

      before do
        session.update_column(:mneme_boundary_message_id, user_msg.id)
        create(:message, :bash_tool_call, session:)
        create(:message, :bash_tool_response, session:)
        create(:message, :user_message, session:, payload: {"content" => "Done"})
      end

      it "compresses tool calls in the transcript" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("[1 tool called]")
        expect(content).not_to include("bash")
      end
    end

    context "with think tool calls" do
      let!(:msg) { create(:message, :user_message, session:, payload: {"content" => "Fix the bug"}) }

      before do
        session.update_column(:mneme_boundary_message_id, msg.id)
        create(:message, :think_tool_call, session:,
          payload: {"tool_name" => "think", "tool_input" => {"thoughts" => "Let me analyze"}})
      end

      it "renders think calls as conversation in the transcript" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("Think: Let me analyze")
      end
    end
  end

  describe "integration with real LLM", vcr: {match_requests_on: [:method, :uri]} do
    it "calls save_snapshot with a meaningful summary" do
      first = create(:message, :user_message, session:, token_count: 20,
        payload: {"content" => "Help me set up OAuth with PKCE for our mobile app"})
      create(:message, :user_message, session:, token_count: 60,
        payload: {"content" => "I'll implement OAuth 2.0 with PKCE. First, we need a code verifier and challenge."})
      create(:message, :user_message, session:, token_count: 15,
        payload: {"content" => "Use the AppAuth library for iOS and handle token refresh"})
      session.update_column(:mneme_boundary_message_id, first.id)

      real_runner = described_class.new(session)
      real_runner.call

      expect(session.snapshots.for_level(1).count).to eq(1)
      snapshot = session.snapshots.for_level(1).first
      expect(snapshot.text).to include("OAuth")
      expect(snapshot.from_message_id).to eq(first.id)
    end
  end
end
