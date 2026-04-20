# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Tools::SurfaceMemory do
  let(:main_session) { Session.create!(name: "Current") }
  let(:memory_session) { Session.create!(name: "Archive") }
  let(:tool) { described_class.new(main_session: main_session) }

  before do
    allow(Anima::Settings).to receive(:recall_max_snippet_tokens).and_return(512)
  end

  def create_message(session, content:, type: "user_message")
    session.messages.create!(
      message_type: type,
      payload: {"content" => content},
      timestamp: Time.current.to_ns
    )
  end

  describe ".schema" do
    it "requires message_id and why" do
      schema = described_class.schema

      expect(schema[:name]).to eq("surface_memory")
      expect(schema[:input_schema][:required]).to contain_exactly("message_id", "why")
    end
  end

  describe "#execute" do
    it "creates a from_mneme PendingMessage on the main session" do
      msg = create_message(memory_session, content: "Refresh tokens require PKCE.")

      expect {
        tool.execute("message_id" => msg.id, "why" => "prior constraint")
      }.to change { main_session.pending_messages.where(source_type: "recall").count }.by(1)

      pm = main_session.pending_messages.find_by(source_type: "recall")
      expect(pm.source_name).to eq(msg.id.to_s)
      expect(pm.message_type).to eq("from_mneme")
    end

    it "embeds the origin session name and content in the PM body" do
      msg = create_message(memory_session, content: "The fix was to rotate the keys.")

      tool.execute("message_id" => msg.id, "why" => "relevant rotation reference")

      pm = main_session.pending_messages.last
      expect(pm.content).to include("message #{msg.id}")
      expect(pm.content).to include("Archive")
      expect(pm.content).to include("rotate the keys")
    end

    it "falls back to a session-id label when the origin has no name" do
      unnamed = Session.create!
      msg = create_message(unnamed, content: "Unnamed origin content.")

      tool.execute("message_id" => msg.id, "why" => "test")

      pm = main_session.pending_messages.last
      expect(pm.content).to include("session ##{unnamed.id}")
    end

    it "returns an error when the message is missing" do
      result = tool.execute("message_id" => 999_999, "why" => "anything")

      expect(result).to be_a(Hash)
      expect(result[:error]).to include("not found")
    end

    it "returns an error when the reason is blank" do
      msg = create_message(memory_session, content: "anything")

      result = tool.execute("message_id" => msg.id, "why" => "  ")

      expect(result).to be_a(Hash)
      expect(result[:error]).to include("blank")
    end

    it "extracts the thought body for think tool_calls" do
      msg = memory_session.messages.create!(
        message_type: "tool_call",
        tool_use_id: "tu_1",
        payload: {
          "tool_name" => "think",
          "tool_use_id" => "tu_1",
          "tool_input" => {"thoughts" => "Considering rotation strategy for OAuth keys."}
        },
        timestamp: Time.current.to_ns
      )

      tool.execute("message_id" => msg.id, "why" => "prior reasoning")

      pm = main_session.pending_messages.last
      expect(pm.content).to include("rotation strategy for OAuth keys")
    end
  end
end
