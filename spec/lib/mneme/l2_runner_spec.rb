# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::L2Runner do
  let(:session) { Session.create! }
  let(:client) { instance_double(LLM::Client) }
  let(:runner) { described_class.new(session, client: client) }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:mneme_viewport_fraction).and_return(0.33)
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
    allow(Anima::Settings).to receive(:fast_model).and_return("claude-haiku-4-5")
    allow(Anima::Settings).to receive(:mneme_l2_snapshot_threshold).and_return(3)
  end

  def create_l1_snapshot(from:, to:, text: "Summary of events #{from}..#{to}")
    session.snapshots.create!(
      text: text, from_event_id: from, to_event_id: to, level: 1, token_count: 50
    )
  end

  describe "#call" do
    it "returns nil when not enough L1 snapshots exist" do
      create_l1_snapshot(from: 1, to: 10)
      create_l1_snapshot(from: 11, to: 20)

      expect(runner.call).to be_nil
    end

    it "does not call the LLM when below threshold" do
      create_l1_snapshot(from: 1, to: 10)

      runner.call

      expect(client).not_to have_received(:chat_with_tools) if client.respond_to?(:chat_with_tools)
    end

    context "with enough L1 snapshots" do
      before do
        create_l1_snapshot(from: 1, to: 10, text: "First conversation about auth")
        create_l1_snapshot(from: 11, to: 20, text: "Implemented OAuth flow")
        create_l1_snapshot(from: 21, to: 30, text: "Added PKCE support")
      end

      it "calls chat_with_tools with L1 snapshot content" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("First conversation about auth")
        expect(content).to include("Implemented OAuth flow")
        expect(content).to include("Added PKCE support")
        expect(content).to include("3 Level 1 snapshots")
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

      it "passes level 2 context to the tool registry" do
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          snapshot_result = opts[:registry].execute("save_snapshot", {"text" => "L2 meta-summary"})
          expect(snapshot_result).to include("Snapshot saved")
          "Done"
        }

        runner.call

        snapshot = Snapshot.for_level(2).last
        expect(snapshot.level).to eq(2)
        expect(snapshot.from_event_id).to eq(1)
        expect(snapshot.to_event_id).to eq(30)
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

      it "includes the L2 system prompt" do
        captured_opts = nil
        allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
          captured_opts = opts
          "Done"
        }

        runner.call

        expect(captured_opts[:system]).to include("Level 2")
        expect(captured_opts[:system]).to include("compress")
      end
    end

    context "with L1 snapshots already covered by L2" do
      before do
        create_l1_snapshot(from: 1, to: 10)
        create_l1_snapshot(from: 11, to: 20)
        # L2 covers both L1 snapshots
        session.snapshots.create!(text: "L2 summary", from_event_id: 1, to_event_id: 20, level: 2, token_count: 80)
        # Only 1 uncovered L1 — below threshold of 3
        create_l1_snapshot(from: 21, to: 30)
      end

      it "excludes covered L1 snapshots from the count" do
        expect(runner.call).to be_nil
      end
    end

    context "with enough uncovered L1 snapshots after partial L2 coverage" do
      before do
        create_l1_snapshot(from: 1, to: 10)
        create_l1_snapshot(from: 11, to: 20)
        session.snapshots.create!(text: "L2 summary", from_event_id: 1, to_event_id: 20, level: 2, token_count: 80)
        create_l1_snapshot(from: 21, to: 30)
        create_l1_snapshot(from: 31, to: 40)
        create_l1_snapshot(from: 41, to: 50)
      end

      it "compresses only the uncovered L1 snapshots" do
        captured_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          captured_messages = msgs
          "Done"
        }

        runner.call

        content = captured_messages.first[:content]
        expect(content).to include("3 Level 1 snapshots")
        expect(content).to include("events 21..30")
        expect(content).not_to include("events 1..10")
      end
    end
  end
end
