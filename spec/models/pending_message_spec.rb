# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingMessage do
  let(:session) { create(:session) }

  describe "#derive_kind (before_validation)" do
    it "populates #kind from MESSAGE_TYPE_KINDS for every supported message_type" do
      PendingMessage::MESSAGE_TYPE_KINDS.each do |message_type, expected_kind|
        pm = build(:pending_message, session: session, message_type: message_type, source_name: "x")
        pm.validate

        expect(pm.kind).to eq(expected_kind), "expected #{message_type} to derive kind=#{expected_kind}"
      end
    end
  end

  describe "validations" do
    it "requires tool_use_id when message_type is tool_response" do
      pm = build(:pending_message, :tool_response, session: session, tool_use_id: nil)
      expect(pm).not_to be_valid
      expect(pm.errors[:tool_use_id]).to be_present
    end

    it "requires source_name for every phantom-pair source_type" do
      PendingMessage::PHANTOM_PAIR_TYPES.each do |source_type|
        pm = build(:pending_message, session: session, source_type: source_type, source_name: nil)
        expect(pm).not_to be_valid, "expected #{source_type} to need source_name"
        expect(pm.errors[:source_name]).to be_present
      end
    end

    it "leaves source_name optional for plain user messages" do
      expect(build(:pending_message, session: session, source_name: nil)).to be_valid
    end
  end

  describe "#to_llm_messages" do
    context "user message" do
      subject(:pm) { build(:pending_message, session: session, content: "hey there") }

      it "returns plain content" do
        expect(pm.to_llm_messages).to eq("hey there")
      end
    end

    context "phantom pair type" do
      subject(:pm) { create(:pending_message, :from_melete_goal, session: session, content: "Goal created") }

      it "returns a tool_use/tool_result pair with matching ids" do
        use_block, result_block = pm.to_llm_messages
        expect(use_block[:role]).to eq("assistant")
        expect(use_block[:content].first[:type]).to eq("tool_use")
        expect(result_block[:role]).to eq("user")
        expect(result_block[:content].first[:type]).to eq("tool_result")
        expect(result_block[:content].first[:tool_use_id]).to eq(use_block[:content].first[:id])
      end
    end
  end

  describe "phantom tool naming" do
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
      expect { create(:pending_message, session: session, content: "waiting") }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "pending_message_created",
          "content" => "waiting",
          "message_type" => "user_message"
        ))
    end

    it "includes the rendered payload for the session's view mode" do
      session.update!(view_mode: "verbose")

      expect { create(:pending_message, :tool_response, session: session, content: "ok", source_name: "bash", tool_use_id: "toolu_x") }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("rendered" => a_hash_including("verbose" => a_hash_including("role" => "tool_response"))))
    end

    it "broadcasts pending_message_removed on destroy" do
      pm = create(:pending_message, session: session)

      expect { pm.destroy! }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_removed", "pending_message_id" => pm.id))
    end
  end

  describe "#route_to_event_bus (after_create_commit)" do
    before { allow(Events::Bus).to receive(:emit).and_call_original }

    context "when session is idle" do
      it "emits StartMneme for user_message" do
        pm = create(:pending_message, session: session)

        expect(Events::Bus).to have_received(:emit).with(
          an_instance_of(Events::StartMneme).and(have_attributes(session_id: session.id, pending_message_id: pm.id))
        )
      end

      it "emits StartProcessing for tool_response" do
        pm = create(:pending_message, :tool_response, session: session)

        expect(Events::Bus).to have_received(:emit).with(
          an_instance_of(Events::StartProcessing).and(have_attributes(pending_message_id: pm.id))
        )
      end

      it "emits StartProcessing for subagent" do
        pm = create(:pending_message, :subagent, session: session)

        expect(Events::Bus).to have_received(:emit).with(
          an_instance_of(Events::StartProcessing).and(have_attributes(pending_message_id: pm.id))
        )
      end

      it "stays silent for background messages" do
        create(:pending_message, :from_mneme, session: session)

        expect(Events::Bus).not_to have_received(:emit).with(
          an_instance_of(Events::StartMneme).or(an_instance_of(Events::StartProcessing))
        )
      end
    end

    context "when session is awaiting" do
      it "stays silent — the idle-wake rule picks it up later" do
        session.start_processing!

        create(:pending_message, session: session)

        expect(Events::Bus).not_to have_received(:emit).with(
          an_instance_of(Events::StartMneme).or(an_instance_of(Events::StartProcessing))
        )
      end
    end

    context "when session is executing and the round is incomplete" do
      it "stays silent — sibling tool_responses are still missing" do
        session.start_processing!
        session.tool_received!
        create(:message, :tool_call, session: session, tool_use_id: "tu_1")
        create(:message, :tool_call, session: session, tool_use_id: "tu_2")

        create(:pending_message, :tool_response, session: session, tool_use_id: "tu_1")

        expect(Events::Bus).not_to have_received(:emit).with(
          an_instance_of(Events::StartMneme).or(an_instance_of(Events::StartProcessing))
        )
      end
    end

    context "when session is executing and the round becomes complete" do
      it "emits StartProcessing — the AASM guard now permits the claim" do
        session.start_processing!
        session.tool_received!
        create(:message, :tool_call, session: session, tool_use_id: "tu_1")
        create(:message, :tool_call, session: session, tool_use_id: "tu_2")
        create(:pending_message, :tool_response, session: session, tool_use_id: "tu_1")

        last = create(:pending_message, :tool_response, session: session, tool_use_id: "tu_2")

        expect(Events::Bus).to have_received(:emit).with(
          an_instance_of(Events::StartProcessing).and(have_attributes(pending_message_id: last.id))
        )
      end
    end
  end

  describe "#promote!" do
    it "promotes a tool_response PM into a tool_response Message and destroys the PM" do
      pm = create(:pending_message, :tool_response,
        session: session, content: "stdout", source_name: "bash", tool_use_id: "tool_123")

      expect { pm.promote! }
        .to change { session.messages.where(message_type: "tool_response").count }.by(1)
        .and change { PendingMessage.where(id: pm.id).count }.by(-1)

      msg = session.messages.find_by(message_type: "tool_response")
      expect(msg.tool_use_id).to eq("tool_123")
      expect(msg.payload["content"]).to eq("stdout")
      expect(pm.promoted_message_id).to eq(msg.id)
    end

    it "promotes a user_message PM via Session#create_user_message and captures the message id" do
      pm = session.pending_messages.create!(
        content: "hello",
        source_type: "user",
        message_type: "user_message"
      )

      expect { pm.promote! }
        .to change { session.messages.where(message_type: "user_message").count }.by(1)

      msg = session.messages.find_by(message_type: "user_message")
      expect(msg.payload["content"]).to eq("hello")
      expect(pm.promoted_message_id).to eq(msg.id)
    end

    describe "phantom pair promotion" do
      it "creates a tool_call + tool_response pair for recall PMs" do
        pm = create(:pending_message, :from_mneme, session: session, content: "recalled text", source_name: "42")

        expect { pm.promote! }
          .to change { session.messages.where(message_type: "tool_call").count }.by(1)
          .and change { session.messages.where(message_type: "tool_response").count }.by(1)
      end

      it "derives tool_use_id from phantom tool name and PM id" do
        pm = create(:pending_message, :from_mneme, session: session, source_name: "42")
        expected_uid = "from_mneme_#{pm.id}"
        pm.promote!

        call = session.messages.find_by(message_type: "tool_call")
        response = session.messages.find_by(message_type: "tool_response")
        expect(call.tool_use_id).to eq(expected_uid)
        expect(response.tool_use_id).to eq(expected_uid)
      end

      it "uses the phantom tool name from PendingMessage" do
        pm = create(:pending_message, :from_melete_goal, session: session, source_name: "7")
        pm.promote!

        call = session.messages.find_by(message_type: "tool_call")
        expect(call.payload["tool_name"]).to eq("from_melete_goal")
      end

      it "stores tool input as stringified keys" do
        pm = create(:pending_message, :from_melete_goal, session: session, source_name: "7")
        pm.promote!

        call = session.messages.find_by(message_type: "tool_call")
        expect(call.payload["tool_input"]).to eq("goal_id" => 7)
      end
    end
  end
end
