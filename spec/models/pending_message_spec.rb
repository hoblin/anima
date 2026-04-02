# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingMessage, type: :model do
  let(:session) { Session.create! }

  describe "source_name is required for phantom pair types" do
    PendingMessage::PHANTOM_PAIR_TYPES.each do |type|
      it "rejects #{type} without source_name" do
        pm = PendingMessage.new(session: session, content: "hi", source_type: type)
        expect(pm).not_to be_valid
        expect(pm.errors[:source_name]).to be_present
      end
    end

    it "allows user messages without source_name" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "user")
      expect(pm).to be_valid
    end
  end

  describe "#to_llm_messages" do
    it "returns plain content for user messages" do
      pm = session.pending_messages.create!(content: "hey there")
      expect(pm.to_llm_messages).to eq("hey there")
    end

    it "returns a tool_use/tool_result pair for phantom pair types" do
      pm = session.pending_messages.create!(
        content: "Goal created: Implement auth (id: 42)",
        source_type: "goal", source_name: "42"
      )

      messages = pm.to_llm_messages

      expect(messages.length).to eq(2)
      expect(messages[0][:role]).to eq("assistant")
      expect(messages[0][:content].first[:type]).to eq("tool_use")
      expect(messages[1][:role]).to eq("user")
      expect(messages[1][:content].first[:type]).to eq("tool_result")
      expect(messages[1][:content].first[:tool_use_id]).to eq(messages[0][:content].first[:id])
    end
  end

  describe "phantom tool mapping" do
    {
      "subagent" => {source_name: "sleuth", tool: "subagent_message", input: {from: "sleuth"}},
      "skill" => {source_name: "testing", tool: "recall_skill", input: {skill: "testing"}},
      "workflow" => {source_name: "feature", tool: "recall_workflow", input: {workflow: "feature"}},
      "recall" => {source_name: "42", tool: "recall_memory", input: {message_id: 42}},
      "goal" => {source_name: "7", tool: "recall_goal", input: {goal_id: 7}}
    }.each do |source_type, meta|
      it "maps #{source_type} to #{meta[:tool]} with correct input" do
        pm = PendingMessage.new(source_type: source_type, source_name: meta[:source_name])
        expect(pm.phantom_tool_name).to eq(meta[:tool])
        expect(pm.phantom_tool_input).to eq(meta[:input])
      end
    end
  end

  describe "broadcasts" do
    it "broadcasts pending_message_created on create" do
      expect {
        session.pending_messages.create!(content: "waiting")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_created", "content" => "waiting"))
    end

    it "broadcasts pending_message_removed on destroy" do
      pm = session.pending_messages.create!(content: "waiting")

      expect {
        pm.destroy!
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_removed", "pending_message_id" => pm.id))
    end
  end

  describe "dependent destroy" do
    it "is destroyed when session is destroyed" do
      session.pending_messages.create!(content: "orphan")

      expect { session.destroy! }.to change(PendingMessage, :count).by(-1)
    end
  end
end
