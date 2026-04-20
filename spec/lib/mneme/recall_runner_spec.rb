# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::RecallRunner do
  subject(:runner) { described_class.new(session, client: client) }

  let(:session) { Session.create! }
  let(:client) { instance_double(LLM::Client) }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
    allow(Anima::Settings).to receive(:fast_model).and_return("claude-haiku-4-5")
    allow(Anima::Settings).to receive(:recall_max_results).and_return(5)
    allow(Anima::Settings).to receive(:recall_max_snippet_tokens).and_return(512)
  end

  def capture_llm_call(response: "Done")
    captured = {}
    allow(client).to receive(:chat_with_tools) { |msgs, **opts|
      captured[:messages] = msgs
      captured[:opts] = opts
      response
    }
    captured
  end

  describe "#call" do
    context "with active goals" do
      before do
        session.goals.create!(description: "Fix the OAuth flow")
      end

      it "frames Aoide's goals in the user message" do
        captured = capture_llm_call

        runner.call

        content = captured[:messages].first[:content]
        expect(content).to include("Fix the OAuth flow")
        expect(content).to include("nothing_to_surface")
      end

      it "gives Mneme the recall task in the system prompt" do
        captured = capture_llm_call

        runner.call

        system = captured[:opts][:system]
        expect(system).to include("Mneme")
        expect(system).to include("recall")
        # Tool names live in the schemas, not in the prompt — see
        # registered_tool_set spec below for tool registration.
        expect(system).to include("query")
        expect(system).to include("surface")
      end

      it "registers the recall tool set" do
        captured = capture_llm_call

        runner.call

        registry = captured[:opts][:registry]
        expect(registry.registered?("search_messages")).to be true
        expect(registry.registered?("view_messages")).to be true
        expect(registry.registered?("surface_memory")).to be true
        expect(registry.registered?("nothing_to_surface")).to be true
      end
    end

    context "without active goals" do
      it "still runs — silence is a valid answer" do
        captured = capture_llm_call

        runner.call

        content = captured[:messages].first[:content]
        expect(content).to include("no active goals right now")
      end
    end

    context "when Mneme surfaces a memory through the tool loop" do
      let(:other_session) { Session.create!(name: "Archive") }
      let!(:memory) {
        other_session.messages.create!(
          message_type: "user_message",
          payload: {"content" => "Remember: refresh tokens require PKCE."},
          timestamp: Time.current.to_ns
        )
      }

      before do
        session.goals.create!(description: "Fix OAuth refresh flow")
      end

      it "creates a from_mneme PendingMessage via surface_memory" do
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          # Simulate Mneme invoking surface_memory through the registry.
          opts[:registry].execute("surface_memory", {
            "message_id" => memory.id,
            "why" => "prior constraint about PKCE matters for this fix"
          })
          "Done"
        }

        expect { runner.call }
          .to change { session.pending_messages.where(source_type: "recall").count }.by(1)

        pm = session.pending_messages.find_by(source_type: "recall")
        expect(pm.source_name).to eq(memory.id.to_s)
        expect(pm.message_type).to eq("from_mneme")
        expect(pm.content).to include("PKCE")
      end
    end

    context "with memories already surfaced earlier in the session" do
      let!(:boundary_message) {
        session.messages.create!(
          message_type: "user_message",
          payload: {"content" => "current"},
          timestamp: Time.current.to_ns
        )
      }

      before do
        session.update_column(:mneme_boundary_message_id, boundary_message.id)
        # Phantom tool_call representing an earlier Mneme recall of message 777.
        session.messages.create!(
          message_type: "tool_call",
          tool_use_id: "from_mneme_phantom_abc",
          payload: {
            "tool_name" => PendingMessage::MNEME_TOOL,
            "tool_use_id" => "from_mneme_phantom_abc",
            "tool_input" => {"message_id" => 777},
            "content" => "Recalling"
          },
          timestamp: Time.current.to_ns
        )
        session.goals.create!(description: "Fix OAuth refresh")
      end

      it "tells Mneme which memories she's already surfaced this cycle" do
        captured = capture_llm_call

        runner.call

        system = captured[:opts][:system]
        expect(system).to include("Already Surfaced")
        expect(system).to include("777")
      end
    end
  end
end
