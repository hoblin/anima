# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingMessage do
  let(:session) { create(:session) }

  describe "#kind (derived from message_type)" do
    PendingMessage::MESSAGE_TYPE_KINDS.each do |mt, expected_kind|
      context "with message_type=#{mt}" do
        subject(:pm) { build(:pending_message, session: session, message_type: mt, source_name: "x") }

        before { pm.validate }

        it "assigns kind=#{expected_kind}" do
          expect(pm.kind).to eq(expected_kind)
        end
      end
    end
  end

  describe "validations" do
    subject(:pm) { build(:pending_message, session: session) }

    it "requires message_type" do
      pm.message_type = nil
      expect(pm).not_to be_valid
      expect(pm.errors[:message_type]).to be_present
    end

    it "requires tool_use_id when message_type is tool_response" do
      pm = build(:pending_message, :tool_response, session: session, tool_use_id: nil)
      expect(pm).not_to be_valid
      expect(pm.errors[:tool_use_id]).to be_present
    end

    context "source_name" do
      PendingMessage::PHANTOM_PAIR_TYPES.each do |source_type|
        it "is required for source_type=#{source_type}" do
          pm = build(:pending_message, session: session, source_type: source_type, source_name: nil)
          expect(pm).not_to be_valid
          expect(pm.errors[:source_name]).to be_present
        end
      end

      it "is optional for user messages" do
        expect(build(:pending_message, session: session, source_name: nil)).to be_valid
      end
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
        .with(a_hash_including("action" => "pending_message_created", "content" => "waiting"))
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
end
