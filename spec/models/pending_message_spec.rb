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
      "subagent" => {source_name: "sleuth", tool: "from_sleuth", input: {from: "sleuth"}},
      "skill" => {source_name: "testing", tool: "from_melete_skill", input: {skill: "testing"}},
      "workflow" => {source_name: "feature", tool: "from_melete_workflow", input: {workflow: "feature"}},
      "recall" => {source_name: "42", tool: "from_mneme", input: {message_id: 42}},
      "goal" => {source_name: "7", tool: "from_melete_goal", input: {goal_id: 7}}
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

  describe "kind enum" do
    it "defaults to active" do
      pm = session.pending_messages.create!(content: "hi")
      expect(pm).to be_active
      expect(pm).not_to be_background
    end

    it "accepts background" do
      pm = session.pending_messages.create!(content: "memory", kind: :background)
      expect(pm).to be_background
    end

    it "exposes scopes" do
      active_pm = session.pending_messages.create!(content: "active msg")
      background_pm = session.pending_messages.create!(content: "background msg", kind: :background)

      expect(PendingMessage.active).to include(active_pm)
      expect(PendingMessage.active).not_to include(background_pm)
      expect(PendingMessage.background).to include(background_pm)
    end
  end

  describe "message_type validation" do
    it "allows nil (legacy callers that predate the drain pipeline)" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "user")
      expect(pm).to be_valid
    end

    PendingMessage::MESSAGE_TYPES.each do |mt|
      it "accepts #{mt}" do
        pm = PendingMessage.new(session: session, content: "hi", source_type: "user", message_type: mt)
        expect(pm).to be_valid
      end
    end

    it "rejects unknown values" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "user", message_type: "bogus")
      expect(pm).not_to be_valid
      expect(pm.errors[:message_type]).to be_present
    end
  end

  describe "#route_to_event_bus (after_create_commit)" do
    before do
      allow(Events::Bus).to receive(:emit).and_call_original
    end

    context "with an active message on an idle session" do
      {"user_message" => Events::StartMneme, "think" => Events::StartMneme}.each do |mt, event_class|
        it "emits #{event_class.name.split("::").last} for #{mt}" do
          pm = session.pending_messages.create!(content: "hello", message_type: mt)

          expect(Events::Bus).to have_received(:emit).with(
            an_instance_of(event_class).and(have_attributes(session_id: session.id, pending_message_id: pm.id))
          )
        end
      end

      {
        "tool_call" => Events::StartProcessing,
        "tool_response" => Events::StartProcessing,
        "subagent" => Events::StartProcessing
      }.each do |mt, event_class|
        it "emits #{event_class.name.split("::").last} for #{mt}" do
          pm = session.pending_messages.create!(
            content: "result",
            source_type: "subagent",
            source_name: "sleuth",
            message_type: mt
          )

          expect(Events::Bus).to have_received(:emit).with(
            an_instance_of(event_class).and(have_attributes(session_id: session.id, pending_message_id: pm.id))
          )
        end
      end
    end

    context "with a background message" do
      ["from_mneme", "from_melete"].each do |mt|
        it "does not emit a start event for #{mt}" do
          session.pending_messages.create!(
            content: "memory",
            source_type: "recall",
            source_name: "42",
            message_type: mt,
            kind: :background
          )

          expect(Events::Bus).not_to have_received(:emit).with(
            an_instance_of(Events::StartMneme).or(an_instance_of(Events::StartProcessing))
          )
        end
      end
    end

    context "with an active message landing while the session is not idle" do
      it "does not emit — the running drain loop will pick it up" do
        session.start_processing!

        session.pending_messages.create!(content: "late arrival", message_type: "user_message")

        expect(Events::Bus).not_to have_received(:emit).with(
          an_instance_of(Events::StartMneme).or(an_instance_of(Events::StartProcessing))
        )
      end
    end

    context "with a legacy caller (message_type nil)" do
      it "does not emit — the pipeline only activates for explicit message types" do
        session.pending_messages.create!(content: "legacy")

        expect(Events::Bus).not_to have_received(:emit).with(
          an_instance_of(Events::StartMneme).or(an_instance_of(Events::StartProcessing))
        )
      end
    end
  end
end
