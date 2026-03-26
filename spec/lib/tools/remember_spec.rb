# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Remember do
  let(:session) { Session.create! }
  let(:tool) { described_class.new(session: session) }

  def create_message(sess, type:, content: "msg", tool_name: nil)
    payload = if type == "tool_call"
      name = tool_name || "bash"
      {"tool_name" => name, "tool_input" => ((name == "think") ? {"thoughts" => content} : {"cmd" => "ls"}), "tool_use_id" => SecureRandom.hex(8)}
    elsif type == "tool_response"
      {"content" => content, "tool_use_id" => SecureRandom.hex(8)}
    else
      {"content" => content}
    end

    sess.messages.create!(
      message_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    )
  end

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("remember") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("remember")
      expect(schema[:description]).to include("conversation")
      expect(schema[:input_schema][:required]).to include("message_id")
    end
  end

  describe "#execute" do
    it "returns error for nonexistent event" do
      result = tool.execute("message_id" => 999999)

      expect(result).to be_a(Hash)
      expect(result[:error]).to include("not found")
    end

    it "returns fractal window centered on the target event" do
      events = 10.times.map { |i| create_message(session, type: "user_message", content: "Message #{i}") }
      target = events[5]

      result = tool.execute("message_id" => target.id)

      expect(result).to include("FULL CONTEXT")
      expect(result).to include("Message 5")
      expect(result).to include("message #{target.id}")
    end

    it "marks the target message with an arrow" do
      target = create_message(session, type: "user_message", content: "Target message")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("→ message #{target.id}")
    end

    it "includes events from before and after the target" do
      create_message(session, type: "user_message", content: "Before target")
      target = create_message(session, type: "user_message", content: "The target event")
      create_message(session, type: "user_message", content: "After target")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("Before target")
      expect(result).to include("The target event")
      expect(result).to include("After target")
    end

    it "compresses tool_response events to status indicators" do
      create_message(session, type: "user_message", content: "Do something")
      tc = create_message(session, type: "tool_call", tool_name: "bash")
      session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "file1.rb\nfile2.rb", "tool_use_id" => tc.payload["tool_use_id"]},
        tool_use_id: tc.tool_use_id,
        timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      )
      target = create_message(session, type: "user_message", content: "Next step")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("ToolResult: [ok]")
      expect(result).not_to include("file1.rb")
    end

    it "shows think events at full resolution" do
      target = create_message(session, type: "tool_call", tool_name: "think",
        content: "Deep reasoning about the problem")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("Think: Deep reasoning about the problem")
    end

    it "includes snapshots before the center range when available" do
      # Create early events so the snapshot range precedes the target
      5.times { create_message(session, type: "user_message", content: "Early message") }
      early_ids = session.messages.pluck(:id)

      session.snapshots.create!(
        text: "Earlier discussion about deployment.",
        from_message_id: early_ids.first, to_message_id: early_ids.last,
        level: 1, token_count: 50
      )

      # Create later events with a gap
      10.times { create_message(session, type: "user_message", content: "Filler message") }
      target = create_message(session, type: "user_message", content: "Later message")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("PREVIOUS CONTEXT")
      expect(result).to include("Earlier discussion about deployment.")
    end

    it "works across sessions — can recall events from other sessions" do
      other_session = Session.create!(name: "Old Session")
      target = create_message(other_session, type: "user_message", content: "Important finding")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("recalled from: Old Session")
      expect(result).to include("Important finding")
    end

    it "includes session name in the header" do
      named_session = Session.create!(name: "Auth Refactoring")
      target = create_message(named_session, type: "user_message", content: "test")

      result = tool.execute("message_id" => target.id)

      expect(result).to include("recalled from: Auth Refactoring")
    end
  end
end
