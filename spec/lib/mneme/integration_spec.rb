# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mneme terminal event trigger integration" do
  let(:session) { create(:session) }

  before do
    allow(Anima::Settings).to receive(:eviction_fraction).and_return(0.33)
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
    allow(Anima::Settings).to receive(:fast_model).and_return("claude-haiku-4-5")
  end

  describe "filling viewport triggers Mneme" do
    let(:budget) { 3000 }
    let(:event_size) { 1000 }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(budget)
    end

    it "initializes boundary on first message, triggers when it evicts" do
      first = create(:message, :user_message, session:, token_count: event_size)
      session.schedule_mneme!
      expect(session.reload.mneme_boundary_message_id).to eq(first.id)

      # Fill viewport (3 messages fit in budget)
      create(:message, :user_message, session:, token_count: event_size)
      create(:message, :user_message, session:, token_count: event_size)
      session.schedule_mneme!
      expect(session.reload.mneme_boundary_message_id).to eq(first.id)

      # 4th message pushes first out of viewport
      create(:message, :user_message, session:, token_count: event_size)

      expect(session.viewport_messages.where(id: first.id).exists?).to be false
      expect { session.schedule_mneme! }.to have_enqueued_job(MnemeJob).with(session.id)
    end
  end

  describe "Mneme runner creates snapshot and advances boundary" do
    let(:client) { instance_double(LLM::Client) }

    it "creates a snapshot and advances boundary through full cycle" do
      first = create(:message, :user_message, session:, token_count: 100)
      create(:message, :user_message, session:, token_count: 100)
      create(:message, :user_message, session:, token_count: 100)
      create(:message, :user_message, session:, token_count: 100)

      session.update_column(:mneme_boundary_message_id, first.id)

      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        opts[:registry].execute("save_snapshot", {"text" => "Discussed OAuth auth flow with PKCE."})
        "Done"
      }

      runner = Mneme::Runner.new(session, client:)
      runner.call

      expect(Snapshot.count).to eq(1)
      snapshot = Snapshot.last
      expect(snapshot.text).to eq("Discussed OAuth auth flow with PKCE.")
      expect(snapshot.session).to eq(session)
      expect(snapshot.level).to eq(1)

      session.reload
      expect(session.mneme_boundary_message_id).to be > first.id
    end
  end

  describe "cycle repeats" do
    let(:client) { instance_double(LLM::Client) }
    let(:budget) { 2000 }
    let(:event_size) { 500 }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(budget)
    end

    it "fires Mneme again when the new boundary leaves viewport" do
      # Budget=2000, each message 500 tokens → holds 4 messages
      first = create(:message, :user_message, session:, token_count: event_size)
      create(:message, :user_message, session:, token_count: event_size)
      create(:message, :user_message, session:, token_count: event_size)
      create(:message, :user_message, session:, token_count: event_size)

      session.update_column(:mneme_boundary_message_id, first.id)

      # 5th message pushes first out of viewport
      create(:message, :user_message, session:, token_count: event_size)

      # First Mneme run — creates snapshot and advances boundary
      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        opts[:registry].execute("save_snapshot", {"text" => "First summary"})
        "Done"
      }

      Mneme::Runner.new(session, client:).call

      new_boundary = session.reload.mneme_boundary_message_id
      expect(new_boundary).to be > first.id

      # Add enough messages to push the new boundary out
      4.times { create(:message, :user_message, session:, token_count: event_size) }

      expect(session.viewport_messages.where(id: new_boundary).exists?).to be false
      expect { session.schedule_mneme! }.to have_enqueued_job(MnemeJob).with(session.id)

      expect(Snapshot.count).to eq(1)
    end
  end

  describe "snapshots in system prompt" do
    let(:client) { instance_double(LLM::Client) }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(10_000)
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
    end

    it "snapshot appears in system prompt once created" do
      e1 = create(:message, :user_message, session:, token_count: 100)
      e2 = create(:message, :user_message, session:, token_count: 100)

      session.snapshots.create!(
        text: "Discussed old topic", from_message_id: e1.id, to_message_id: e2.id, level: 1, token_count: 50
      )

      section = session.send(:assemble_snapshots_section)
      expect(section).to include("Discussed old topic")
    end
  end

  describe "L2 compression cycle" do
    let(:client) { instance_double(LLM::Client) }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(10_000)
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
      allow(Anima::Settings).to receive(:mneme_l2_snapshot_threshold).and_return(3)
    end

    it "L2 compression replaces L1 snapshots in system prompt" do
      e1 = create(:message, :user_message, session:, token_count: 500)
      e2 = create(:message, :user_message, session:, token_count: 500)
      e3 = create(:message, :user_message, session:, token_count: 500)
      e4 = create(:message, :user_message, session:, token_count: 500)
      e5 = create(:message, :user_message, session:, token_count: 500)
      e6 = create(:message, :user_message, session:, token_count: 500)

      session.snapshots.create!(text: "L1 first", from_message_id: e1.id, to_message_id: e2.id, level: 1, token_count: 50)
      session.snapshots.create!(text: "L1 second", from_message_id: e3.id, to_message_id: e4.id, level: 1, token_count: 50)
      session.snapshots.create!(text: "L1 third", from_message_id: e5.id, to_message_id: e6.id, level: 1, token_count: 50)

      section_before = session.send(:assemble_snapshots_section)
      expect(section_before).to include("L1 first")
      expect(section_before).to include("L1 second")
      expect(section_before).to include("L1 third")

      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        opts[:registry].execute("save_snapshot", {"text" => "L2 meta-summary of all three"})
        "Done"
      }
      Mneme::L2Runner.new(session, client:).call

      section_after = session.send(:assemble_snapshots_section)
      expect(section_after).not_to include("L1 first")
      expect(section_after).to include("L2 meta-summary of all three")
    end
  end

  describe "eviction preserves recent sliding window (regression: #422)" do
    let(:client) { instance_double(LLM::Client) }
    let(:budget) { 9000 }
    let(:event_size) { 1000 }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(budget)
      allow(Anima::Settings).to receive(:mneme_pinned_budget_fraction).and_return(0.0)
    end

    it "evicts only the oldest third, not the entire sliding window" do
      msgs = 12.times.map do |i|
        create(:message, :user_message, session:, token_count: event_size,
          payload: {"content" => "msg_#{i}"})
      end

      session.update_column(:mneme_boundary_message_id, msgs[0].id)

      expect(session.viewport_messages.where(id: msgs[0].id).exists?).to be false

      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        opts[:registry].execute("save_snapshot", {"text" => "Summary of msgs 0-2"})
        "Done"
      }

      Mneme::Runner.new(session, client:).call
      session.reload

      expect(session.mneme_boundary_message_id).to be <= msgs[3].id

      llm_messages = session.messages_for_llm
      message_texts = llm_messages.flat_map { |m|
        content = m[:content]
        content.is_a?(String) ? [content] : []
      }

      # Recent messages must survive — the sliding window was NOT wiped
      expect(message_texts.any? { |t| t.include?("msg_11") }).to be(true),
        "Expected msg_11 in viewport but sliding window was wiped"
      expect(message_texts.any? { |t| t.include?("msg_10") }).to be(true)
      expect(message_texts.any? { |t| t.include?("msg_9") }).to be(true)
    end

    it "boundary advances by roughly one-third of the viewport, not to the end" do
      msgs = 12.times.map do |i|
        create(:message, :user_message, session:, token_count: event_size,
          payload: {"content" => "msg_#{i}"})
      end

      session.update_column(:mneme_boundary_message_id, msgs[0].id)

      allow(client).to receive(:chat_with_tools) { "Done" }

      Mneme::Runner.new(session, client:).call
      session.reload

      new_boundary = session.mneme_boundary_message_id
      expect(new_boundary).to be <= msgs[4].id
      expect(new_boundary).to be > msgs[0].id
    end
  end
end
