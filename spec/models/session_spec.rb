# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  # Computes the expected LLM content for a user message with timestamp prefix.
  # Must stay in sync with Session#format_event_time.
  def timestamped(content, timestamp_ns)
    time = Time.at(timestamp_ns / 1_000_000_000.0).utc
    "#{time.strftime("%a %b %-d %H:%M")}\n#{content}"
  end

  describe "AASM state machine" do
    describe "initial state" do
      it "starts as idle" do
        session = described_class.create!
        expect(session).to be_idle
      end
    end

    describe "transitions" do
      let(:session) { create(:session) }

      it "transitions from idle to awaiting via start_processing!" do
        expect(session.start_processing!).to be_truthy
        expect(session).to be_awaiting
      end

      it "transitions from awaiting to executing via tool_received!" do
        session.start_processing!
        expect(session.tool_received!).to be_truthy
        expect(session).to be_executing
      end

      it "transitions from awaiting to idle via response_complete!" do
        session.start_processing!
        expect(session.response_complete!).to be_truthy
        expect(session).to be_idle
      end

      it "transitions from executing to awaiting via tool_complete!" do
        session.start_processing!
        session.tool_received!
        expect(session.tool_complete!).to be_truthy
        expect(session).to be_awaiting
      end

      it "transitions from executing to idle via finish!" do
        session.start_processing!
        session.tool_received!
        expect(session.finish!).to be_truthy
        expect(session).to be_idle
      end

      it "transitions from any state to idle via interrupt!" do
        session.start_processing!
        session.tool_received!
        expect(session).to be_executing

        expect(session.interrupt!).to be_truthy
        expect(session).to be_idle
      end
    end

    describe "guards" do
      let(:session) { create(:session) }

      it "rejects start_processing from awaiting" do
        session.start_processing!
        expect(session.start_processing!).to be_falsey
      end

      it "rejects tool_received from idle" do
        expect(session.tool_received!).to be_falsey
      end

      it "rejects response_complete from idle" do
        expect(session.response_complete!).to be_falsey
      end

      it "rejects tool_complete from idle" do
        expect(session.tool_complete!).to be_falsey
      end

      it "rejects finish from idle" do
        expect(session.finish!).to be_falsey
      end
    end

    describe "may_ predicates" do
      let(:session) { create(:session) }

      it "reports valid transitions from idle" do
        expect(session.may_start_processing?).to be true
        expect(session.may_tool_received?).to be false
        expect(session.may_interrupt?).to be true
      end

      it "reports valid transitions from awaiting" do
        session.start_processing!
        expect(session.may_start_processing?).to be false
        expect(session.may_tool_received?).to be true
        expect(session.may_response_complete?).to be true
      end

      it "reports valid transitions from executing" do
        session.start_processing!
        session.tool_received!
        expect(session.may_tool_complete?).to be true
        expect(session.may_finish?).to be true
        expect(session.may_response_complete?).to be false
      end
    end

    describe "no_direct_assignment" do
      it "prevents direct aasm_state assignment" do
        session = create(:session)
        expect { session.aasm_state = "awaiting" }.to raise_error(AASM::NoDirectAssignmentError)
      end
    end

    describe "persistence" do
      it "persists state transitions to the database" do
        session = create(:session)
        session.start_processing!
        expect(session.reload.aasm_state).to eq("awaiting")
      end
    end

    describe "scopes" do
      it "provides state-based scopes" do
        idle_session = create(:session)
        awaiting_session = create(:session, :awaiting)
        executing_session = create(:session, :executing)

        expect(described_class.idle).to include(idle_session)
        expect(described_class.awaiting).to include(awaiting_session)
        expect(described_class.executing).to include(executing_session)
      end
    end
  end

  describe "validations" do
    it "accepts valid view modes" do
      session = Session.new
      %w[basic verbose debug].each do |mode|
        session.view_mode = mode
        expect(session).to be_valid
      end
    end

    it "rejects invalid view modes" do
      session = Session.new(view_mode: "fancy")
      expect(session).not_to be_valid
      expect(session.errors[:view_mode]).to be_present
    end

    it "defaults view_mode to the configured setting" do
      allow(Anima::Settings).to receive(:default_view_mode).and_return("basic")
      session = Session.create!
      expect(session.view_mode).to eq("basic")
    end

    it "respects a non-default view mode from settings" do
      allow(Anima::Settings).to receive(:default_view_mode).and_return("verbose")
      session = Session.create!
      expect(session.view_mode).to eq("verbose")
    end
  end

  describe "associations" do
    it "has many events ordered by id" do
      session = Session.create!
      event_a = session.messages.create!(message_type: "user_message", payload: {content: "first"}, timestamp: 1)
      event_b = session.messages.create!(message_type: "user_message", payload: {content: "second"}, timestamp: 2)

      expect(session.messages.reload).to eq([event_a, event_b])
    end

    it "destroys events when session is destroyed" do
      session = Session.create!
      session.messages.create!(message_type: "user_message", payload: {content: "hi"}, timestamp: 1)

      expect { session.destroy }.to change(Message, :count).by(-1)
    end

    it "belongs to parent_session (optional)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "test prompt")

      expect(child.parent_session).to eq(parent)
    end

    it "allows sessions without a parent" do
      session = Session.create!
      expect(session.parent_session).to be_nil
    end

    it "has many child_sessions" do
      parent = Session.create!
      child_a = Session.create!(parent_session: parent, prompt: "agent A")
      child_b = Session.create!(parent_session: parent, prompt: "agent B")

      expect(parent.child_sessions).to contain_exactly(child_a, child_b)
    end

    it "destroys child sessions when parent is destroyed" do
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "child")

      expect { parent.destroy }.to change(Session, :count).by(-2)
    end
  end

  describe "#broadcast_children_update_to_parent" do
    it "broadcasts children list to parent session stream" do
      parent = Session.create!
      child_a = Session.create!(parent_session: parent, prompt: "agent A", name: "analyzer")
      child_b = create(:session, :awaiting, parent_session: parent, prompt: "agent B", name: "reviewer")

      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{parent.id}",
        {
          "action" => "children_updated",
          "session_id" => parent.id,
          "children" => [
            {"id" => child_a.id, "name" => "analyzer", "aasm_state" => "idle", "session_state" => "idle"},
            {"id" => child_b.id, "name" => "reviewer", "aasm_state" => "awaiting", "session_state" => "llm_generating"}
          ]
        }
      )

      child_a.broadcast_children_update_to_parent
    end

    it "does nothing for root sessions" do
      root = Session.create!

      expect(ActionCable.server).not_to receive(:broadcast)

      root.broadcast_children_update_to_parent
    end

    it "handles deleted parent gracefully" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")
      parent.destroy!

      # Broadcasts to the stream (no crash) — stream has no subscribers
      expect { child.broadcast_children_update_to_parent }.not_to raise_error
    end

    it "selects only needed columns for payload" do
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "task", name: "worker")

      payload = nil
      allow(ActionCable.server).to receive(:broadcast) { |_, data| payload = data }

      Session.last.broadcast_children_update_to_parent

      child_data = payload["children"].first
      expect(child_data.keys).to contain_exactly("id", "name", "aasm_state", "session_state")
    end
  end

  describe "#broadcast_session_state" do
    it "broadcasts state to the session stream" do
      session = Session.create!

      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{session.id}",
        {"action" => "session_state", "state" => "llm_generating", "session_id" => session.id}
      )

      session.broadcast_session_state("llm_generating")
    end

    it "includes tool name for tool_executing state" do
      session = Session.create!

      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{session.id}",
        {"action" => "session_state", "state" => "tool_executing", "tool" => "bash", "session_id" => session.id}
      )

      session.broadcast_session_state("tool_executing", tool: "bash")
    end

    it "broadcasts child_state to parent stream for sub-agents" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")

      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{child.id}",
        {"action" => "session_state", "state" => "llm_generating", "session_id" => child.id}
      ).ordered
      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{parent.id}",
        {"action" => "child_state", "state" => "llm_generating", "session_id" => child.id, "child_id" => child.id}
      ).ordered

      child.broadcast_session_state("llm_generating")
    end

    it "does not broadcast to parent for root sessions" do
      session = Session.create!

      expect(ActionCable.server).to receive(:broadcast).once

      session.broadcast_session_state("idle")
    end
  end

  describe ".root_sessions" do
    it "returns only sessions without a parent" do
      root = Session.create!
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "child")

      expect(Session.root_sessions).to include(root, parent)
      expect(Session.root_sessions).not_to include(Session.where.not(parent_session_id: nil).to_a.first)
    end
  end

  describe "#name" do
    it "stores agent name for named sub-agents" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "prompt", name: "codebase-analyzer")

      expect(child.reload.name).to eq("codebase-analyzer")
    end

    it "returns nil for unnamed sessions" do
      session = Session.create!
      expect(session.name).to be_nil
    end

    it "rejects names longer than 255 characters" do
      parent = Session.create!
      child = Session.new(parent_session: parent, prompt: "prompt", name: "a" * 256)
      expect(child).not_to be_valid
      expect(child.errors[:name]).to be_present
    end

    it "accepts names up to 255 characters" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "prompt", name: "a" * 255)
      expect(child).to be_valid
    end
  end

  describe "#schedule_melete!" do
    it "enqueues MeleteJob for unnamed root sessions with messages" do
      session = Session.create!
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      session.messages.create!(message_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { session.schedule_melete! }
        .to have_enqueued_job(MeleteJob).with(session.id)
    end

    it "enqueues for sub-agent sessions (skills and naming)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")
      child.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      child.messages.create!(message_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { child.schedule_melete! }
        .to have_enqueued_job(MeleteJob).with(child.id)
    end

    it "does not enqueue for sessions with fewer than 2 messages" do
      session = Session.create!
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)

      expect { session.schedule_melete! }
        .not_to have_enqueued_job(MeleteJob)
    end

    it "enqueues for named sessions on every qualifying message" do
      session = Session.create!(name: "Already Named")
      session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      session.messages.create!(message_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { session.schedule_melete! }
        .to have_enqueued_job(MeleteJob).with(session.id)
    end
  end

  describe "#broadcast_name_update" do
    it "broadcasts name change to the session stream" do
      session = Session.create!

      expect {
        session.update!(name: "🎉 New Name")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "session_name_updated",
          "session_id" => session.id,
          "name" => "🎉 New Name"
        ))
    end

    it "does not broadcast when name is unchanged" do
      session = Session.create!(name: "Same Name")

      expect {
        session.update!(view_mode: "verbose")
      }.not_to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "session_name_updated"))
    end
  end

  describe "#active_skills" do
    subject(:active_skills) { session.active_skills }

    let(:session) { create(:session) }

    before do
      Skills::Registry.reload!
      allow(session).to receive(:viewport_messages).and_return(viewport)
    end

    context "with no skills anywhere" do
      let(:viewport) { Message.none }

      it "returns an empty array" do
        expect(active_skills).to eq([])
      end
    end

    context "with a skill in the viewport" do
      let(:skill) { create(:message, :from_melete_skill, session:, skill_name: "gh-issue") }
      let(:viewport) { Message.where(id: skill.id) }

      it "includes the viewport skill" do
        expect(active_skills).to eq(["gh-issue"])
      end
    end

    context "with a queued pending skill" do
      let(:viewport) { Message.none }

      before { session.activate_skill("gh-issue") }

      it "includes the pending skill" do
        expect(active_skills).to eq(["gh-issue"])
      end
    end

    context "with the same skill in viewport and pending" do
      let(:skill) { create(:message, :from_melete_skill, session:, skill_name: "gh-issue") }
      let(:viewport) { Message.where(id: skill.id) }

      before { session.activate_skill("gh-issue") }

      it "deduplicates" do
        expect(active_skills).to eq(["gh-issue"])
      end
    end

    context "with viewport and pending skills" do
      let(:skill) { create(:message, :from_melete_skill, session:, skill_name: "rspec") }
      let(:viewport) { Message.where(id: skill.id) }

      before { session.activate_skill("gh-issue") }

      it "returns viewport skills first, then pending" do
        expect(active_skills).to eq(%w[rspec gh-issue])
      end
    end
  end

  describe "#active_workflow" do
    subject(:active_workflow) { session.active_workflow }

    let(:session) { create(:session) }

    before do
      Workflows::Registry.reload!
      allow(session).to receive(:viewport_messages).and_return(viewport)
    end

    context "with no workflow anywhere" do
      let(:viewport) { Message.none }

      it "returns nil" do
        expect(active_workflow).to be_nil
      end
    end

    context "with a workflow in the viewport" do
      let(:workflow) { create(:message, :from_melete_workflow, session:, workflow_name: "feature") }
      let(:viewport) { Message.where(id: workflow.id) }

      it "returns the viewport workflow" do
        expect(active_workflow).to eq("feature")
      end
    end

    context "with a queued pending workflow" do
      let(:viewport) { Message.none }

      before { session.activate_workflow("feature") }

      it "returns the pending workflow" do
        expect(active_workflow).to eq("feature")
      end
    end

    context "with a pending workflow overriding the viewport" do
      let(:workflow) { create(:message, :from_melete_workflow, session:, workflow_name: "refactor") }
      let(:viewport) { Message.where(id: workflow.id) }

      before { session.activate_workflow("feature") }

      it "returns the pending workflow (last enqueue wins)" do
        expect(active_workflow).to eq("feature")
      end
    end

    context "with multiple pending workflows" do
      let(:viewport) { Message.none }

      before do
        session.pending_messages.create!(content: "old", source_type: "workflow", source_name: "refactor")
        session.pending_messages.create!(content: "new", source_type: "workflow", source_name: "feature")
      end

      it "returns the newest pending workflow" do
        expect(active_workflow).to eq("feature")
      end
    end
  end

  describe "#broadcast_active_state!" do
    before do
      Skills::Registry.reload!
      Workflows::Registry.reload!
    end

    let(:session) { create(:session) }

    it "broadcasts the current active skills list" do
      session.activate_skill("gh-issue")

      expect { session.broadcast_active_state! }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_skills_updated",
          "session_id" => session.id,
          "active_skills" => ["gh-issue"]))
    end

    it "broadcasts the current active workflow" do
      session.activate_workflow("feature")

      expect { session.broadcast_active_state! }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_workflow_updated",
          "session_id" => session.id,
          "active_workflow" => "feature"))
    end

    it "broadcasts empty state when no skills or workflows are active" do
      expect { session.broadcast_active_state! }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_skills_updated", "active_skills" => []))
        .and have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_workflow_updated", "active_workflow" => nil))
    end

    it "broadcasts both skills and workflow when they coexist" do
      session.activate_skill("gh-issue")
      session.activate_workflow("feature")

      expect { session.broadcast_active_state! }
        .to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_skills_updated", "active_skills" => ["gh-issue"]))
        .and have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_workflow_updated", "active_workflow" => "feature"))
    end
  end

  describe "#granted_tools" do
    it "returns nil when not set" do
      session = Session.create!
      expect(session.granted_tools).to be_nil
    end

    it "round-trips an array of tool names through JSON serialization" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "agent", granted_tools: ["read_file", "web_get"])

      expect(child.reload.granted_tools).to eq(["read_file", "web_get"])
    end

    it "round-trips an empty array (pure reasoning)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "thinker", granted_tools: [])

      expect(child.reload.granted_tools).to eq([])
    end
  end

  describe "#sub_agent?" do
    it "returns true for child sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")

      expect(child).to be_sub_agent
    end

    it "returns false for main sessions" do
      session = Session.create!
      expect(session).not_to be_sub_agent
    end
  end

  describe "#effective_token_budget" do
    it "returns main token_budget for root sessions" do
      session = Session.create!
      expect(session.effective_token_budget).to eq(Anima::Settings.token_budget)
    end

    it "returns subagent_token_budget for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")
      expect(child.effective_token_budget).to eq(Anima::Settings.subagent_token_budget)
    end
  end

  describe "#initial_cwd" do
    it "stores the parent working directory for sub-agents" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task", initial_cwd: "/home/user/project")

      expect(child.reload.initial_cwd).to eq("/home/user/project")
    end

    it "defaults to nil for root sessions" do
      session = Session.create!
      expect(session.initial_cwd).to be_nil
    end
  end

  describe "#system_prompt" do
    before { Skills::Registry.reload! }

    it "returns prompt for sub-agent sessions (bypasses soul)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")

      expect(child.system_prompt).to eq("You are a research assistant.")
    end

    it "includes task section when sub-agent has an active goal" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")
      Goal.create!(session: child, description: "Analyze the authentication module")

      prompt = child.system_prompt
      expect(prompt).to include("Your Task\n=========")
      expect(prompt).to include("Analyze the authentication module")
      expect(prompt).to include("mark_goal_completed")
    end

    it "excludes task section when sub-agent goal is completed" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")
      Goal.create!(session: child, description: "Done task", status: "completed", completed_at: 1.hour.ago)

      expect(child.system_prompt).to eq("You are a research assistant.")
    end

    it "places stored prompt before task section for sub-agents" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a focused sub-agent.")
      Goal.create!(session: child, description: "Find the bug")

      prompt = child.system_prompt
      prompt_pos = prompt.index("You are a focused sub-agent.")
      task_pos = prompt.index("Your Task\n=========")
      expect(prompt_pos).to be < task_pos
    end

    it "activates skills via phantom pair promotion for sub-agents too" do
      child = create(:session, :sub_agent)

      expect { child.activate_skill("gh-issue") }
        .to change { child.pending_messages.where(source_type: "skill").count }.by(1)
    end

    it "includes soul content for main sessions" do
      session = Session.create!

      expect(session.system_prompt).to include("# Soul")
    end

    it "excludes goals from system prompt entirely" do
      session = Session.create!
      Goal.create!(session:, description: "Test goal")

      prompt = session.system_prompt
      expect(prompt).not_to include("Current Goals")
      expect(prompt).not_to include("Test goal")
    end

    it "does not include environment context in system prompt" do
      session = Session.create!

      prompt = session.system_prompt
      expect(prompt).to start_with("You are running on Anima v")
      expect(prompt).to include("# Soul")
      expect(prompt).not_to include("## Environment")
    end
  end

  describe "#activate_skill" do
    before { Skills::Registry.reload! }

    let(:session) { create(:session) }

    it "returns the skill definition" do
      result = session.activate_skill("gh-issue")

      expect(result).to be_a(Skills::Definition)
      expect(result.name).to eq("gh-issue")
    end

    it "raises for unknown skills" do
      expect { session.activate_skill("nonexistent") }
        .to raise_error(Skills::InvalidDefinitionError, /Unknown skill/)
    end

    it "is idempotent — does not enqueue a duplicate while the skill is still pending" do
      session.activate_skill("gh-issue")

      expect { session.activate_skill("gh-issue") }
        .not_to change { session.pending_messages.count }
    end

    it "creates a PendingMessage with source_type skill" do
      expect { session.activate_skill("gh-issue") }
        .to change { session.pending_messages.where(source_type: "skill").count }.by(1)

      pm = session.pending_messages.last
      expect(pm.source_name).to eq("gh-issue")
      expect(pm.content).to include("WHAT/WHY/HOW")
    end

    it "surfaces the skill as active immediately after activation" do
      session.activate_skill("gh-issue")

      expect(session.active_skills).to include("gh-issue")
    end

    it "is still idempotent after promotion when the phantom pair is in the viewport" do
      session.activate_skill("gh-issue")
      session.promote_pending_messages!

      expect { session.activate_skill("gh-issue") }
        .not_to change { session.pending_messages.count }
    end
  end

  describe "#from_melete_messages" do
    subject(:from_melete_messages) { session.send(:from_melete_messages) }

    let(:session) { create(:session) }

    before { allow(session).to receive(:viewport_messages).and_return(viewport) }

    context "with an empty viewport" do
      let(:viewport) { Message.none }

      it "returns an ActiveRecord relation" do
        expect(from_melete_messages).to be_a(ActiveRecord::Relation)
      end

      it "returns no messages" do
        expect(from_melete_messages).to be_empty
      end
    end

    context "with from_melete_skill tool calls" do
      let(:skill) { create(:message, :from_melete_skill, session:) }
      let(:viewport) { Message.where(id: skill.id) }

      it "includes them" do
        expect(from_melete_messages).to contain_exactly(skill)
      end
    end

    context "with from_melete_workflow tool calls" do
      let(:workflow) { create(:message, :from_melete_workflow, session:) }
      let(:viewport) { Message.where(id: workflow.id) }

      it "includes them" do
        expect(from_melete_messages).to contain_exactly(workflow)
      end
    end

    context "with from_melete_goal tool calls" do
      let(:goal) { create(:message, :from_melete_goal, session:) }
      let(:viewport) { Message.where(id: goal.id) }

      it "includes them" do
        expect(from_melete_messages).to contain_exactly(goal)
      end
    end

    context "with from_mneme tool calls" do
      let(:mneme) do
        create(:message, :tool_call, session:, payload: {
          "tool_name" => PendingMessage::MNEME_TOOL,
          "tool_input" => {"message_id" => 1},
          "tool_use_id" => "from_mneme_1",
          "content" => "recalled"
        })
      end
      let(:viewport) { Message.where(id: mneme.id) }

      it "excludes them" do
        expect(from_melete_messages).to be_empty
      end
    end

    context "with subagent tool calls" do
      let(:subagent) do
        create(:message, :tool_call, session:, payload: {
          "tool_name" => "from_sleuth",
          "tool_input" => {"from" => "sleuth"},
          "tool_use_id" => "from_sleuth_1",
          "content" => "result"
        })
      end
      let(:viewport) { Message.where(id: subagent.id) }

      it "excludes them" do
        expect(from_melete_messages).to be_empty
      end
    end

    context "with non-tool_call message types" do
      let(:user_msg) { create(:message, :user_message, session:) }
      let(:skill) { create(:message, :from_melete_skill, session:) }
      let(:viewport) { Message.where(id: [user_msg.id, skill.id]) }

      it "excludes them and keeps only melete tool calls" do
        expect(from_melete_messages).to contain_exactly(skill)
      end
    end

    context "with a subagent nicknamed to resemble melete" do
      let(:impostor) do
        create(:message, :tool_call, session:, payload: {
          "tool_name" => "from_melete-spy",
          "tool_input" => {"from" => "melete-spy"},
          "tool_use_id" => "from_melete-spy_1",
          "content" => "spy result"
        })
      end
      let(:viewport) { Message.where(id: impostor.id) }

      it "excludes them — underscores in the query are literal, not wildcards" do
        expect(from_melete_messages).to be_empty
      end
    end

    context "with mixed melete contributions" do
      let(:skill) { create(:message, :from_melete_skill, session:, skill_name: "rspec") }
      let(:workflow) { create(:message, :from_melete_workflow, session:, workflow_name: "feature") }
      let(:goal) { create(:message, :from_melete_goal, session:) }
      let(:viewport) { Message.where(id: [skill.id, workflow.id, goal.id]) }

      it "returns them in activation (id) order" do
        expect(from_melete_messages.pluck(:id)).to eq([skill.id, workflow.id, goal.id])
      end
    end
  end

  describe "#skills_in_viewport" do
    let(:session) { create(:session) }

    it "returns an empty array when viewport has no from_melete_skill calls" do
      unrelated = create(:message, :user_message, session:)
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: unrelated.id))

      expect(session.skills_in_viewport).to eq([])
    end

    it "extracts skill names from from_melete_skill tool_call messages" do
      skill_call = create(:message, :from_melete_skill, session:, skill_name: "gh-issue")
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: skill_call.id))

      expect(session.skills_in_viewport).to eq(["gh-issue"])
    end

    it "excludes from_melete_skill calls that are not in the viewport" do
      create(:message, :from_melete_skill, session:, skill_name: "gh-issue")
      allow(session).to receive(:viewport_messages).and_return(Message.none)

      expect(session.skills_in_viewport).to eq([])
    end

    it "ignores from_melete_workflow calls" do
      workflow_call = create(:message, :from_melete_workflow, session:, workflow_name: "feature")
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: workflow_call.id))

      expect(session.skills_in_viewport).to eq([])
    end

    it "returns skills in activation (message id) order" do
      first = create(:message, :from_melete_skill, session:, skill_name: "testing")
      second = create(:message, :from_melete_skill, session:, skill_name: "gh-issue")
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: [first.id, second.id]))

      expect(session.skills_in_viewport).to eq(%w[testing gh-issue])
    end
  end

  describe "#workflow_in_viewport" do
    let(:session) { create(:session) }

    it "returns nil when no workflow call is in viewport" do
      allow(session).to receive(:viewport_messages).and_return(Message.none)

      expect(session.workflow_in_viewport).to be_nil
    end

    it "extracts the workflow name from a from_melete_workflow call" do
      workflow_call = create(:message, :from_melete_workflow, session:, workflow_name: "feature")
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: workflow_call.id))

      expect(session.workflow_in_viewport).to eq("feature")
    end

    it "returns the most recently activated workflow when multiple are visible" do
      older = create(:message, :from_melete_workflow, session:, workflow_name: "refactor")
      newer = create(:message, :from_melete_workflow, session:, workflow_name: "feature")
      allow(session).to receive(:viewport_messages).and_return(Message.where(id: [older.id, newer.id]))

      expect(session.workflow_in_viewport).to eq("feature")
    end
  end

  describe "#assemble_system_prompt" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "always starts with the soul" do
      expect(session.assemble_system_prompt).to start_with("You are running on Anima v")
    end

    it "includes the sisters block introducing Melete and Mneme" do
      prompt = session.assemble_system_prompt

      expect(prompt).to include("## Your Sisters")
      expect(prompt).to include("Melete")
      expect(prompt).to include("from_melete_skill")
      expect(prompt).to include("Mneme")
      expect(prompt).to include("from_mneme")
      expect(prompt).to include("`from_` prefix")
    end

    it "places the sisters block after the soul and before snapshots" do
      prompt = session.assemble_system_prompt
      sisters_idx = prompt.index("## Your Sisters")
      preamble_idx = prompt.index("You are running on Anima v")

      expect(sisters_idx).to be > preamble_idx
    end

    it "does not include expertise section — skills flow through messages" do
      session.activate_skill("gh-issue")

      expect(session.assemble_system_prompt).not_to include("## Your Expertise")
      expect(session.assemble_system_prompt).not_to include("WHAT/WHY/HOW")
    end

    context "with multiple skills" do
      let(:tmp_dir) { Dir.mktmpdir }

      before do
        File.write(File.join(tmp_dir, "testing.md"), <<~MD)
          ---
          name: testing
          description: "Testing best practices"
          ---

          # Testing Guide

          Write thorough tests.
        MD

        Skills::Registry.reload!
        Skills::Registry.instance.load_directory(tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it "preserves activation order" do
        session.activate_skill("testing")
        session.activate_skill("gh-issue")

        expect(session.active_skills).to eq(%w[testing gh-issue])
      end
    end
  end

  describe "#assemble_soul_section" do
    let(:session) { Session.create! }

    it "raises MissingSoulError when soul file does not exist" do
      allow(Anima::Settings).to receive(:soul_path).and_return("/nonexistent/soul.md")

      expect { session.send(:assemble_soul_section) }
        .to raise_error(Session::MissingSoulError, /Run `anima install`/)
    end
  end

  describe "goals association" do
    it "has many goals" do
      session = Session.create!
      goal = Goal.create!(session:, description: "test goal")

      expect(session.goals).to eq([goal])
    end

    it "destroys goals when session is destroyed" do
      session = Session.create!
      Goal.create!(session:, description: "doomed")

      expect { session.destroy }.to change(Goal, :count).by(-1)
    end
  end

  describe "#goals_summary" do
    let(:session) { Session.create! }

    it "returns empty array when no goals exist" do
      expect(session.goals_summary).to eq([])
    end

    it "returns root goals with their sub-goals" do
      root = Goal.create!(session:, description: "Implement auth")
      Goal.create!(session:, parent_goal: root, description: "Read code")
      Goal.create!(session:, parent_goal: root, description: "Write tests", status: "completed")

      summary = session.goals_summary
      expect(summary.size).to eq(1)
      expect(summary.first["description"]).to eq("Implement auth")
      expect(summary.first["status"]).to eq("active")
      expect(summary.first["sub_goals"].size).to eq(2)
      expect(summary.first["sub_goals"].first["description"]).to eq("Read code")
      expect(summary.first["sub_goals"].last["status"]).to eq("completed")
    end

    it "excludes sub-goals from root level" do
      root = Goal.create!(session:, description: "root")
      Goal.create!(session:, parent_goal: root, description: "child")

      summary = session.goals_summary
      expect(summary.size).to eq(1)
      expect(summary.first["description"]).to eq("root")
    end

    it "orders root goals by created_at" do
      first = Goal.create!(session:, description: "first")
      second = Goal.create!(session:, description: "second")

      summary = session.goals_summary
      expect(summary.map { |g| g["id"] }).to eq([first.id, second.id])
    end

    it "excludes evicted root goals" do
      Goal.create!(session:, description: "visible")
      Goal.create!(session:, description: "evicted", status: "completed",
        completed_at: 2.hours.ago, evicted_at: 1.hour.ago)

      summary = session.goals_summary
      expect(summary.size).to eq(1)
      expect(summary.first["description"]).to eq("visible")
    end

    it "excludes sub-goals of evicted root goals" do
      evicted_root = Goal.create!(session:, description: "evicted root",
        status: "completed", completed_at: 2.hours.ago, evicted_at: 1.hour.ago)
      Goal.create!(session:, parent_goal: evicted_root, description: "orphaned child")
      Goal.create!(session:, description: "visible root")

      summary = session.goals_summary
      expect(summary.size).to eq(1)
      expect(summary.first["description"]).to eq("visible root")
    end
  end

  describe "#assemble_task_section" do
    it "returns task section with active goal description" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a sub-agent.")
      Goal.create!(session: child, description: "Analyze the authentication module")

      section = child.send(:assemble_task_section)
      expect(section).to include("Your Task\n=========")
      expect(section).to include("Analyze the authentication module")
      expect(section).to include("call mark_goal_completed when done")
    end

    it "returns nil when no active goals exist" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a sub-agent.")

      expect(child.send(:assemble_task_section)).to be_nil
    end

    it "returns nil when goal is completed" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a sub-agent.")
      Goal.create!(session: child, description: "Done", status: "completed", completed_at: 1.hour.ago)

      expect(child.send(:assemble_task_section)).to be_nil
    end

    it "works for main sessions too" do
      session = Session.create!
      Goal.create!(session:, description: "Build feature X")

      section = session.send(:assemble_task_section)
      expect(section).to include("Build feature X")
    end
  end

  describe "#assemble_system_prompt with goals" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "excludes goals from system prompt — they flow as phantom pairs" do
      Goal.create!(session:, description: "Implement feature")

      prompt = session.assemble_system_prompt
      expect(prompt).to start_with("You are running on Anima v")
      expect(prompt).not_to include("Current Goals")
      expect(prompt).not_to include("Implement feature")
    end

    it "system prompt is stable regardless of goal changes" do
      prompt_before = session.assemble_system_prompt
      Goal.create!(session:, description: "New goal")
      prompt_after = session.assemble_system_prompt

      expect(prompt_before).to eq(prompt_after)
    end

    it "does not auto-evict completed goals by message count" do
      goal = Goal.create!(session:, description: "Ongoing work")
      goal.update!(status: "completed", completed_at: Time.current)

      20.times do |i|
        session.messages.create!(message_type: "user_message", payload: {content: "msg #{i}"}, timestamp: i + 1)
      end

      expect(goal.reload.evicted_at).to be_nil
    end
  end

  describe "#activate_workflow" do
    before { Workflows::Registry.reload! }

    let(:session) { create(:session) }

    it "returns the workflow definition" do
      result = session.activate_workflow("feature")

      expect(result).to be_a(Workflows::Definition)
      expect(result.name).to eq("feature")
    end

    it "raises for unknown workflows" do
      expect { session.activate_workflow("nonexistent") }
        .to raise_error(Workflows::InvalidDefinitionError, /Unknown workflow/)
    end

    it "is idempotent — does not enqueue a duplicate while the workflow is still pending" do
      session.activate_workflow("feature")

      expect { session.activate_workflow("feature") }
        .not_to change { session.pending_messages.count }
    end

    it "creates a PendingMessage with source_type workflow" do
      expect { session.activate_workflow("feature") }
        .to change { session.pending_messages.where(source_type: "workflow").count }.by(1)

      pm = session.pending_messages.last
      expect(pm.source_name).to eq("feature")
      expect(pm.content).to include("branch creation to PR readiness")
    end

    it "surfaces the workflow as active immediately after activation" do
      session.activate_workflow("feature")

      expect(session.active_workflow).to eq("feature")
    end

    it "enqueues the replacement when activating a different workflow" do
      session.activate_workflow("feature")
      session.promote_pending_messages!

      expect { session.activate_workflow("commit") }
        .to change { session.pending_messages.where(source_type: "workflow").count }.by(1)
    end
  end

  describe "#broadcast_debug_context" do
    it "broadcasts system prompt payload in debug mode" do
      session = Session.create!(view_mode: "debug")

      expect {
        session.broadcast_debug_context(system: "You are Anima.")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "type" => "system_prompt",
          "rendered" => {"debug" => a_hash_including(
            "role" => "system_prompt", "content" => "You are Anima.",
            "tokens" => a_value > 0, "estimated" => true
          )}
        ))
    end

    it "includes tool schemas when provided" do
      session = Session.create!(view_mode: "debug")
      tools = [{"name" => "bash", "description" => "Run commands"}]

      expect {
        session.broadcast_debug_context(system: "You are Anima.", tools: tools)
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "rendered" => {"debug" => a_hash_including("tools" => tools)}
        ))
    end

    it "does not broadcast in basic mode" do
      session = Session.create!(view_mode: "basic")

      expect {
        session.broadcast_debug_context(system: "You are Anima.")
      }.not_to have_broadcasted_to("session_#{session.id}")
    end

    it "does not broadcast in verbose mode" do
      session = Session.create!(view_mode: "verbose")

      expect {
        session.broadcast_debug_context(system: "You are Anima.")
      }.not_to have_broadcasted_to("session_#{session.id}")
    end

    it "does not broadcast when system prompt is nil" do
      session = Session.create!(view_mode: "debug")

      expect {
        session.broadcast_debug_context(system: nil)
      }.not_to have_broadcasted_to("session_#{session.id}")
    end
  end

  describe ".system_prompt_payload" do
    it "builds the expected payload structure without tools" do
      payload = Session.system_prompt_payload("Test prompt")

      expect(payload).to eq({
        "id" => Message::SYSTEM_PROMPT_ID,
        "type" => "system_prompt",
        "rendered" => {
          "debug" => {role: :system_prompt, content: "Test prompt", tokens: 3, estimated: true}
        }
      })
    end

    it "includes tools and estimates combined tokens" do
      tools = [{"name" => "bash", "description" => "Run commands", "input_schema" => {"type" => "object"}}]
      payload = Session.system_prompt_payload("Test", tools: tools)

      debug = payload["rendered"]["debug"]
      expect(debug[:tools]).to eq(tools)
      # Token estimate covers both prompt and tool JSON
      prompt_only_tokens = [TokenEstimation.estimate_token_count("Test"), 1].max
      expect(debug[:tokens]).to be > prompt_only_tokens
    end

    it "omits tools key when tools are empty" do
      payload = Session.system_prompt_payload("Test", tools: [])

      expect(payload["rendered"]["debug"]).not_to have_key(:tools)
    end

    it "estimates at least 1 token for tiny prompts" do
      payload = Session.system_prompt_payload("hi")

      expect(payload["rendered"]["debug"][:tokens]).to eq(1)
    end
  end

  describe "#tool_schemas" do
    it "returns standard + spawn tools for main sessions" do
      session = Session.create!
      schemas = session.tool_schemas
      names = schemas.map { |s| s[:name] }

      expect(names).to include("bash", "read_file", "write_file", "edit_file", "web_get", "think", "view_messages", "search_messages")
      expect(names).to include("spawn_subagent", "spawn_specialist", "open_issue")
      expect(names).not_to include("mark_goal_completed")
    end

    it "returns granted tools + mark_goal_completed for sub-agents" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "sub", granted_tools: ["read_file", "web_get"])
      schemas = child.tool_schemas
      names = schemas.map { |s| s[:name] }

      expect(names).to include("think", "read_file", "web_get", "mark_goal_completed")
      expect(names).not_to include("bash", "spawn_subagent")
    end

    it "returns only always-granted tools for sub-agents with empty granted_tools" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "reasoning only", granted_tools: [])
      schemas = child.tool_schemas
      names = schemas.map { |s| s[:name] }

      expect(names).to include("think", "mark_goal_completed")
      expect(names).not_to include("bash", "read_file", "write_file", "spawn_subagent")
    end

    it "returns all standard tools when granted_tools is nil" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "full agent")
      schemas = child.tool_schemas
      names = schemas.map { |s| s[:name] }

      AgentLoop::STANDARD_TOOLS.each do |tool|
        expect(names).to include(tool.tool_name)
      end
    end
  end

  describe "#assemble_system_prompt with workflows" do
    before do
      Skills::Registry.reload!
      Workflows::Registry.reload!
    end

    let(:session) { Session.create! }

    it "does not include workflow content — workflows flow through messages" do
      session.activate_workflow("feature")

      prompt = session.assemble_system_prompt
      expect(prompt).not_to include("## Your Expertise")
      expect(prompt).not_to include("branch creation to PR readiness")
    end

    it "returns only soul when no goals are present" do
      expect(session.assemble_system_prompt).to start_with("You are running on Anima v")
    end
  end

  describe "#messages_for_llm" do
    let(:session) { Session.create! }

    it "returns user_message events with user role and timestamp prefix" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "hello"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "user", content: timestamped("hello", 1)}])
    end

    it "returns agent_message events with assistant role" do
      session.messages.create!(message_type: "agent_message", payload: {"content" => "hi there"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "assistant", content: "hi there"}])
    end

    it "includes system_message events as user role with [system] prefix" do
      session.messages.create!(message_type: "system_message", payload: {"content" => "MCP: server failed"}, timestamp: 1)

      messages = session.messages_for_llm
      expect(messages.size).to eq(1)
      expect(messages.first[:role]).to eq("user")
      expect(messages.first[:content]).to eq("[system] MCP: server failed")
    end

    context "with tool events" do
      it "assembles tool_call events as assistant messages with tool_use blocks" do
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_123"},
          tool_use_id: "toolu_123",
          timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "<html>hello</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_123", "success" => true},
          tool_use_id: "toolu_123",
          timestamp: 2
        )

        result = session.messages_for_llm
        assistant_msg = result.find { |m| m[:role] == "assistant" }
        expect(assistant_msg[:content]).to eq([
          {type: "tool_use", id: "toolu_123", name: "web_get", input: {"url" => "https://example.com"}}
        ])
      end

      it "assembles tool_response events as user messages with tool_result blocks" do
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_123"},
          tool_use_id: "toolu_123",
          timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "<html>hello</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_123", "success" => true},
          tool_use_id: "toolu_123",
          timestamp: 2
        )

        result = session.messages_for_llm
        user_msg = result.find { |m| m[:role] == "user" }
        expect(user_msg[:content]).to eq([
          {type: "tool_result", tool_use_id: "toolu_123", content: "<html>hello</html>"}
        ])
      end

      it "groups consecutive tool_call events into one assistant message" do
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://a.com"}, "tool_use_id" => "toolu_1"},
          tool_use_id: "toolu_1",
          timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://b.com"}, "tool_use_id" => "toolu_2"},
          tool_use_id: "toolu_2",
          timestamp: 2
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page A", "tool_name" => "web_get", "tool_use_id" => "toolu_1"},
          tool_use_id: "toolu_1",
          timestamp: 3
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page B", "tool_name" => "web_get", "tool_use_id" => "toolu_2"},
          tool_use_id: "toolu_2",
          timestamp: 4
        )

        result = session.messages_for_llm
        assistant_msg = result.find { |m| m[:role] == "assistant" }
        expect(assistant_msg[:content].length).to eq(2)
      end

      it "groups consecutive tool_response events into one user message" do
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://a.com"}, "tool_use_id" => "toolu_1"},
          tool_use_id: "toolu_1",
          timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://b.com"}, "tool_use_id" => "toolu_2"},
          tool_use_id: "toolu_2",
          timestamp: 2
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page A", "tool_name" => "web_get", "tool_use_id" => "toolu_1"},
          tool_use_id: "toolu_1",
          timestamp: 3
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page B", "tool_name" => "web_get", "tool_use_id" => "toolu_2"},
          tool_use_id: "toolu_2",
          timestamp: 4
        )

        result = session.messages_for_llm
        user_msg = result.find { |m| m[:role] == "user" }
        expect(user_msg[:content].length).to eq(2)
      end

      it "assembles a full tool conversation correctly" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "what is on example.com?"}, timestamp: 1)
        session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_abc"},
          tool_use_id: "toolu_abc",
          timestamp: 2
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "<html>Example Domain</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_abc", "success" => true},
          tool_use_id: "toolu_abc",
          timestamp: 3
        )
        session.messages.create!(message_type: "agent_message", payload: {"content" => "The page says Example Domain."}, timestamp: 4)

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "user", content: timestamped("what is on example.com?", 1)},
          {role: "assistant", content: [
            {type: "tool_use", id: "toolu_abc", name: "web_get", input: {"url" => "https://example.com"}}
          ]},
          {role: "user", content: [
            {type: "tool_result", tool_use_id: "toolu_abc", content: "<html>Example Domain</html>"}
          ]},
          {role: "assistant", content: "The page says Example Domain."}
        ])
      end
    end

    context "with out-of-order tool responses (issue #419)" do
      it "pairs tool results by tool_use_id when responses are persisted in reverse order" do
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "bash", "tool_input" => {"cmd" => "ls"},
                    "tool_use_id" => "toolu_first"},
          tool_use_id: "toolu_first", timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "web_get", "tool_input" => {"url" => "https://b.com"},
                    "tool_use_id" => "toolu_second"},
          tool_use_id: "toolu_second", timestamp: 2
        )
        # Responses persisted in REVERSE order (toolu_second completed first)
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page B", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_second"},
          tool_use_id: "toolu_second", timestamp: 3
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "file.txt", "tool_name" => "bash",
                    "tool_use_id" => "toolu_first"},
          tool_use_id: "toolu_first", timestamp: 4
        )

        result = session.messages_for_llm
        assistant_msg = result.find { |m| m[:role] == "assistant" }
        user_msg = result.find { |m| m[:role] == "user" }

        # Calls grouped in one assistant message
        expect(assistant_msg[:content]).to eq([
          {type: "tool_use", id: "toolu_first", name: "bash", input: {"cmd" => "ls"}},
          {type: "tool_use", id: "toolu_second", name: "web_get", input: {"url" => "https://b.com"}}
        ])
        # Results follow call order (by tool_use_id match), not persistence order
        expect(user_msg[:content]).to eq([
          {type: "tool_result", tool_use_id: "toolu_first", content: "file.txt"},
          {type: "tool_result", tool_use_id: "toolu_second", content: "page B"}
        ])
      end

      it "pairs correctly when tool responses are separated by an agent message" do
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "bash", "tool_input" => {},
                    "tool_use_id" => "toolu_a"},
          tool_use_id: "toolu_a", timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "web_get", "tool_input" => {},
                    "tool_use_id" => "toolu_b"},
          tool_use_id: "toolu_b", timestamp: 2
        )
        # Response for toolu_b arrives first
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page B", "tool_use_id" => "toolu_b"},
          tool_use_id: "toolu_b", timestamp: 3
        )
        # An agent message lands between the two tool responses
        # (e.g. a sub-agent delivery promoted into the conversation)
        session.messages.create!(
          message_type: "agent_message",
          payload: {"content" => "Processing..."},
          timestamp: 4
        )
        # Response for toolu_a arrives last
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "done", "tool_use_id" => "toolu_a"},
          tool_use_id: "toolu_a", timestamp: 5
        )

        result = session.messages_for_llm

        # Tool pair is assembled correctly: calls batched, results paired by ID
        expect(result[0][:role]).to eq("assistant")
        expect(result[0][:content]).to eq([
          {type: "tool_use", id: "toolu_a", name: "bash", input: {}},
          {type: "tool_use", id: "toolu_b", name: "web_get", input: {}}
        ])
        expect(result[1][:role]).to eq("user")
        expect(result[1][:content]).to eq([
          {type: "tool_result", tool_use_id: "toolu_a", content: "done"},
          {type: "tool_result", tool_use_id: "toolu_b", content: "page B"}
        ])
        # Agent message follows the tool pair (not interleaved into it)
        expect(result[2]).to eq({role: "assistant", content: "Processing..."})
      end

      it "handles multiple separate tool rounds with interleaved agent responses" do
        # Round 1
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "bash", "tool_input" => {"cmd" => "pwd"},
                    "tool_use_id" => "toolu_r1"},
          tool_use_id: "toolu_r1", timestamp: 1
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "/home", "tool_use_id" => "toolu_r1"},
          tool_use_id: "toolu_r1", timestamp: 2
        )
        # Agent thinks between rounds
        session.messages.create!(
          message_type: "agent_message",
          payload: {"content" => "Now let me check the files."},
          timestamp: 3
        )
        # Round 2 — parallel, responses reversed
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "bash", "tool_input" => {"cmd" => "ls"},
                    "tool_use_id" => "toolu_r2a"},
          tool_use_id: "toolu_r2a", timestamp: 4
        )
        session.messages.create!(
          message_type: "tool_call",
          payload: {"tool_name" => "web_get", "tool_input" => {"url" => "https://x.com"},
                    "tool_use_id" => "toolu_r2b"},
          tool_use_id: "toolu_r2b", timestamp: 5
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "page X", "tool_use_id" => "toolu_r2b"},
          tool_use_id: "toolu_r2b", timestamp: 6
        )
        session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "file.rb", "tool_use_id" => "toolu_r2a"},
          tool_use_id: "toolu_r2a", timestamp: 7
        )

        result = session.messages_for_llm

        # Round 1: single tool pair
        expect(result[0][:role]).to eq("assistant")
        expect(result[0][:content]).to eq([
          {type: "tool_use", id: "toolu_r1", name: "bash", input: {"cmd" => "pwd"}}
        ])
        expect(result[1][:role]).to eq("user")
        expect(result[1][:content]).to eq([
          {type: "tool_result", tool_use_id: "toolu_r1", content: "/home"}
        ])

        # Agent message between rounds
        expect(result[2]).to eq({role: "assistant", content: "Now let me check the files."})

        # Round 2: parallel pair, results in call order despite reversed persistence
        expect(result[3][:role]).to eq("assistant")
        expect(result[3][:content].length).to eq(2)
        expect(result[4][:role]).to eq("user")
        expect(result[4][:content]).to eq([
          {type: "tool_result", tool_use_id: "toolu_r2a", content: "file.rb"},
          {type: "tool_result", tool_use_id: "toolu_r2b", content: "page X"}
        ])
      end
    end

    it "preserves event order" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "first"}, timestamp: 1)
      session.messages.create!(message_type: "agent_message", payload: {"content" => "second"}, timestamp: 2)
      session.messages.create!(message_type: "user_message", payload: {"content" => "third"}, timestamp: 3)

      expect(session.messages_for_llm).to eq([
        {role: "user", content: timestamped("first", 1)},
        {role: "assistant", content: "second"},
        {role: "user", content: timestamped("third", 3)}
      ])
    end

    context "with token budget" do
      before do
        allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.0)
        allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.0)
        allow(Anima::Settings).to receive(:mneme_pinned_budget_fraction).and_return(0.0)
        allow(Anima::Settings).to receive(:recall_budget_fraction).and_return(0.0)
      end

      it "includes all events when within budget" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2, token_count: 10)

        expect(session.messages_for_llm(token_budget: 100)).to eq([
          {role: "user", content: timestamped("hi", 1)},
          {role: "assistant", content: "hello"}
        ])
      end

      it "drops oldest events when budget exceeded" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 50)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 50)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 50)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "recent reply"}, timestamp: 4, token_count: 50)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([
          {role: "user", content: timestamped("recent", 3)},
          {role: "assistant", content: "recent reply"}
        ])
      end

      it "always includes at least the newest event even if it exceeds budget" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "big message"}, timestamp: 1, token_count: 500)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([{role: "user", content: timestamped("big message", 1)}])
      end

      it "uses heuristic estimate for events with zero token_count" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "x" * 400}, timestamp: 1, token_count: 0)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        # "x" * 400 => ~100 token estimate, plus 10 = 110, fits in 200
        result = session.messages_for_llm(token_budget: 200)
        expect(result.length).to eq(2)
      end

      it "returns events in chronological order" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "first"}, timestamp: 1, token_count: 10)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "second"}, timestamp: 2, token_count: 10)
        session.messages.create!(message_type: "user_message", payload: {"content" => "third"}, timestamp: 3, token_count: 10)

        result = session.messages_for_llm(token_budget: 30)

        expect(result.map { |m| m[:content] }).to eq([timestamped("first", 1), "second", timestamped("third", 3)])
      end
    end

    context "with snapshots" do
      let(:session) { Session.create! }

      before do
        allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
        allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
        allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
      end

      it "does not include snapshots in the message array" do
        e1 = session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 10)
        e2 = session.messages.create!(message_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 10)
        recent = session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 10)

        session.snapshots.create!(text: "Summary", from_message_id: e1.id, to_message_id: e2.id, level: 1, token_count: 20)
        session.update_column(:mneme_boundary_message_id, recent.id)

        result = session.messages_for_llm(token_budget: 1000)

        contents = result.map { |m| m[:content].to_s }
        expect(contents.none? { |c| c.include?("Summary") }).to be true
      end

      it "includes L1 snapshots in the system prompt via assemble_snapshots_section" do
        e1 = session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 10)
        e2 = session.messages.create!(message_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 10)
        recent = session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 10)

        session.snapshots.create!(text: "Earlier discussion summary", from_message_id: e1.id, to_message_id: e2.id, level: 1, token_count: 20)
        session.update_column(:mneme_boundary_message_id, recent.id)

        section = session.send(:assemble_snapshots_section)

        expect(section).to include("Recent Memory")
        expect(section).to include("Earlier discussion summary")
      end

      it "places L2 snapshots above L1 snapshots in the section" do
        e1 = session.messages.create!(message_type: "user_message", payload: {"content" => "old1"}, timestamp: 1, token_count: 10)
        e2 = session.messages.create!(message_type: "agent_message", payload: {"content" => "old2"}, timestamp: 2, token_count: 10)
        e3 = session.messages.create!(message_type: "user_message", payload: {"content" => "old3"}, timestamp: 3, token_count: 10)
        e4 = session.messages.create!(message_type: "agent_message", payload: {"content" => "old4"}, timestamp: 4, token_count: 10)
        recent = session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 5, token_count: 10)

        session.snapshots.create!(text: "L2 meta-summary", from_message_id: e1.id, to_message_id: e2.id, level: 2, token_count: 20)
        session.snapshots.create!(text: "L1 uncovered", from_message_id: e3.id, to_message_id: e4.id, level: 1, token_count: 20)
        session.update_column(:mneme_boundary_message_id, recent.id)

        section = session.send(:assemble_snapshots_section)

        expect(section).to include("Long-term Memory")
        expect(section).to include("Recent Memory")
        expect(section.index("Long-term Memory")).to be < section.index("Recent Memory")
      end

      it "drops L1 snapshots covered by L2" do
        e1 = session.messages.create!(message_type: "user_message", payload: {"content" => "old1"}, timestamp: 1, token_count: 10)
        e2 = session.messages.create!(message_type: "agent_message", payload: {"content" => "old2"}, timestamp: 2, token_count: 10)
        e3 = session.messages.create!(message_type: "user_message", payload: {"content" => "old3"}, timestamp: 3, token_count: 10)
        e4 = session.messages.create!(message_type: "agent_message", payload: {"content" => "old4"}, timestamp: 4, token_count: 10)
        recent = session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 5, token_count: 10)

        session.snapshots.create!(text: "L1 covered a", from_message_id: e1.id, to_message_id: e2.id, level: 1, token_count: 20)
        session.snapshots.create!(text: "L1 covered b", from_message_id: e3.id, to_message_id: e4.id, level: 1, token_count: 20)
        session.snapshots.create!(text: "L2 covers both", from_message_id: e1.id, to_message_id: e4.id, level: 2, token_count: 30)
        session.update_column(:mneme_boundary_message_id, recent.id)

        section = session.send(:assemble_snapshots_section)

        expect(section).to include("L2 covers both")
        expect(section).not_to include("L1 covered")
      end

      it "skips snapshot injection for sub-agent sessions" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1, token_count: 10)

        # Parent has a snapshot — child should not see it
        parent.snapshots.create!(text: "Parent snapshot", from_message_id: 1, to_message_id: 5, level: 1, token_count: 20)

        result = child.messages_for_llm(token_budget: 1000)

        contents = result.map { |m| m[:content] }
        expect(contents.none? { |c| c.include?("Parent snapshot") }).to be true
      end

      it "reduces sliding window budget by snapshot and pinned budget fractions" do
        # Budget 1000, l1_fraction=0.15, l2_fraction=0.05, pinned_fraction=0.05
        # Sliding budget = 1000 - 150 - 50 - 50 = 750
        session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 500)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 500)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 500)

        result = session.messages_for_llm(token_budget: 1000)

        # With 750 token sliding budget: only newest event fits (500 < 750, next 500 exceeds remaining 250)
        event_contents = result.reject { |m| m[:content].to_s.start_with?("[") }.map { |m| m[:content] }
        expect(event_contents.size).to eq(1)
      end
    end

    context "with context prefix (goals + pinned messages)" do
      let(:session) { Session.create! }

      before do
        allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
        allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
        allow(Anima::Settings).to receive(:mneme_pinned_budget_fraction).and_return(0.05)
      end

      # Extracts the tool_result content from the context prefix phantom pair.
      def prefix_content(result)
        result.find { |m|
          m[:role] == "user" && m[:content].is_a?(Array) &&
            m[:content].any? { |c| c[:tool_use_id]&.start_with?("goal_snapshot_") }
        }&.dig(:content, 0, :content)
      end

      it "includes goals and pinned messages as a phantom pair before sliding window" do
        old_event = session.messages.create!(message_type: "user_message", payload: {"content" => "critical instruction"}, timestamp: 1, token_count: 500)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        goal = session.goals.create!(description: "Active goal")
        pin = PinnedMessage.create!(message: old_event, display_text: "critical instruction")
        GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

        result = session.messages_for_llm(token_budget: 100)

        content = prefix_content(result)
        expect(content).to be_present
        expect(content).to include("critical instruction")
        expect(content).to include("Active goal")
      end

      it "excludes context prefix when no messages have evicted from viewport" do
        event = session.messages.create!(message_type: "user_message", payload: {"content" => "visible"}, timestamp: 1, token_count: 10)

        goal = session.goals.create!(description: "Goal")
        pin = PinnedMessage.create!(message: event, display_text: "visible")
        GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

        result = session.messages_for_llm(token_budget: 1000)

        expect(prefix_content(result)).to be_nil
      end

      it "deduplicates pinned messages across goals — first shows text, second shows bare ID" do
        old_event = session.messages.create!(message_type: "user_message", payload: {"content" => "shared"}, timestamp: 1, token_count: 500)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        goal_a = session.goals.create!(description: "Goal A")
        goal_b = session.goals.create!(description: "Goal B")
        pin = PinnedMessage.create!(message: old_event, display_text: "shared")
        GoalPinnedMessage.create!(goal: goal_a, pinned_message: pin)
        GoalPinnedMessage.create!(goal: goal_b, pinned_message: pin)

        result = session.messages_for_llm(token_budget: 100)

        content = prefix_content(result)
        expect(content).to be_present
        expect(content).to include("message #{old_event.id}: shared")
        expect(content).to match(/📌 message #{old_event.id}\n|📌 message #{old_event.id}$/)
      end

      it "does not leak parent goals/pins into sub-agent viewport" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        old_event = parent.messages.create!(message_type: "user_message", payload: {"content" => "pinned"}, timestamp: 1, token_count: 10)
        child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 2, token_count: 10)

        goal = parent.goals.create!(description: "Goal")
        pin = PinnedMessage.create!(message: old_event, display_text: "pinned")
        GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

        result = child.messages_for_llm(token_budget: 1000)

        expect(prefix_content(result)).to be_nil
      end

      it "surfaces sub-agent's own pinned task message when evicted from viewport" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        task_msg = child.messages.create!(message_type: "user_message", payload: {"content" => "analyze this code"}, timestamp: 1, token_count: 50)
        child.messages.create!(message_type: "agent_message", payload: {"content" => "working on it"}, timestamp: 2, token_count: 50)

        goal = child.goals.create!(description: "analyze this code")
        pin = PinnedMessage.create!(message: task_msg, display_text: "analyze this code")
        GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

        # Sliding budget (80 - 5% pinned = 76) fits only the agent_message (50 tokens),
        # evicting task_msg — the context prefix should resurface it.
        result = child.messages_for_llm(token_budget: 80)

        content = prefix_content(result)
        expect(content).to be_present
        expect(content).to include("analyze this code")
      end

      it "shows goals without pins when no pinned messages exist" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 500)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)
        session.goals.create!(description: "Active goal")

        result = session.messages_for_llm(token_budget: 100)

        content = prefix_content(result)
        expect(content).to be_present
        expect(content).to include("Current Goals")
        expect(content).to include("Active goal")
      end

      it "excludes completed goals from the context prefix" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 500)
        session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)
        session.goals.create!(description: "Active goal")
        session.goals.create!(description: "Done goal", status: "completed", completed_at: 1.hour.ago)

        result = session.messages_for_llm(token_budget: 100)

        content = prefix_content(result)
        expect(content).to include("Active goal")
        expect(content).not_to include("Done goal")
      end
    end
  end

  describe "#heal_orphaned_tool_calls!" do
    let(:session) { Session.create! }

    it "creates synthetic responses for expired tool_calls without matching tool_response" do
      expired_ts = Time.current.to_ns - (200 * 1_000_000_000)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_orphan", "timeout" => 180},
        tool_use_id: "toolu_orphan",
        timestamp: expired_ts
      )

      expect { session.heal_orphaned_tool_calls! }.to change { session.messages.where(message_type: "tool_response").count }.by(1)

      response = session.messages.find_by(message_type: "tool_response", tool_use_id: "toolu_orphan")
      expect(response.payload["success"]).to be false
      expect(response.payload["content"]).to include("timed out")
      expect(response.payload["tool_name"]).to eq("bash")
    end

    it "does not heal tool_calls still within their timeout window" do
      recent_ts = Time.current.to_ns - (10 * 1_000_000_000)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_fresh", "timeout" => 180},
        tool_use_id: "toolu_fresh",
        timestamp: recent_ts
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.messages.count }
    end

    it "respects per-call timeout override from the agent" do
      called_5_min_ago = Time.current.to_ns - (300 * 1_000_000_000)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_long", "timeout" => 600},
        tool_use_id: "toolu_long",
        timestamp: called_5_min_ago
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.messages.count }
    end

    it "does not create responses for tool_calls that already have one" do
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_ok"},
        tool_use_id: "toolu_ok",
        timestamp: 1
      )
      session.messages.create!(
        message_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_ok", "content" => "output"},
        tool_use_id: "toolu_ok",
        timestamp: 2
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.messages.count }
    end

    it "rejects tool_calls with nil tool_use_id at validation" do
      event = session.messages.new(
        message_type: "tool_call",
        payload: {"tool_name" => "bash"},
        tool_use_id: nil,
        timestamp: 1
      )

      expect(event).not_to be_valid
      expect(event.errors[:tool_use_id]).to include("can't be blank")
    end

    it "heals multiple orphaned tool_calls in a single pass" do
      expired_ts = Time.current.to_ns - (200 * 1_000_000_000)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_a", "timeout" => 180},
        tool_use_id: "toolu_a",
        timestamp: expired_ts
      )
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "web_get", "tool_use_id" => "toolu_b", "timeout" => 60},
        tool_use_id: "toolu_b",
        timestamp: expired_ts
      )

      expect(session.heal_orphaned_tool_calls!).to eq(2)

      expect(session.messages.where(message_type: "tool_response", tool_use_id: "toolu_a")).to exist
      expect(session.messages.where(message_type: "tool_response", tool_use_id: "toolu_b")).to exist
    end

    it "falls back to Settings.tool_timeout when payload has no timeout key" do
      allow(Anima::Settings).to receive(:tool_timeout).and_return(60)
      expired_ts = Time.current.to_ns - (90 * 1_000_000_000)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_no_timeout"},
        tool_use_id: "toolu_no_timeout",
        timestamp: expired_ts
      )

      expect { session.heal_orphaned_tool_calls! }.to change { session.messages.where(message_type: "tool_response").count }.by(1)

      response = session.messages.find_by(message_type: "tool_response", tool_use_id: "toolu_no_timeout")
      expect(response.payload["content"]).to include("60 seconds")
    end

    it "is idempotent — second call creates no duplicates" do
      expired_ts = Time.current.to_ns - (200 * 1_000_000_000)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_orphan", "timeout" => 180},
        tool_use_id: "toolu_orphan",
        timestamp: expired_ts
      )

      session.heal_orphaned_tool_calls!
      expect { session.heal_orphaned_tool_calls! }.not_to change { session.messages.count }
    end
  end

  describe "#messages_for_llm atomic tool pairs" do
    let(:session) { Session.create! }

    before do
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.0)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.0)
      allow(Anima::Settings).to receive(:mneme_pinned_budget_fraction).and_return(0.0)
      allow(Anima::Settings).to receive(:recall_budget_fraction).and_return(0.0)
    end

    it "excludes tool_call events whose tool_response was cut off by token budget" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "go"}, timestamp: 1, token_count: 10)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_cut", "tool_input" => {}},
        tool_use_id: "toolu_cut",
        timestamp: 2,
        token_count: 10
      )
      session.messages.create!(
        message_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_cut", "content" => "ok"},
        tool_use_id: "toolu_cut",
        timestamp: 3,
        token_count: 10
      )
      session.messages.create!(message_type: "agent_message", payload: {"content" => "done"}, timestamp: 4, token_count: 10)
      session.messages.create!(message_type: "user_message", payload: {"content" => "more"}, timestamp: 5, token_count: 10)

      # Budget fits newest 3 events but cuts the tool_call (event 2).
      # tool_response (event 3) would be orphaned without atomic pair enforcement.
      result = session.messages_for_llm(token_budget: 30)

      tool_results = result.select { |m| m[:content].is_a?(Array) }
      expect(tool_results).to be_empty
    end

    it "keeps complete tool pairs within the viewport" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "go"}, timestamp: 1, token_count: 10)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_1", "tool_input" => {}},
        tool_use_id: "toolu_1",
        timestamp: 2,
        token_count: 10
      )
      session.messages.create!(
        message_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_1", "content" => "ok"},
        tool_use_id: "toolu_1",
        timestamp: 3,
        token_count: 10
      )
      session.messages.create!(message_type: "agent_message", payload: {"content" => "done"}, timestamp: 4, token_count: 10)

      result = session.messages_for_llm(token_budget: 40)

      tool_results = result.select { |m| m[:content].is_a?(Array) }
      expect(tool_results.length).to eq(2)
    end

    it "heals expired orphaned tool_calls before assembling messages" do
      expired_ts = Time.current.to_ns - (200 * 1_000_000_000)
      now_ts = Time.current.to_ns
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_dead", "tool_input" => {}, "timeout" => 180},
        tool_use_id: "toolu_dead",
        timestamp: expired_ts,
        token_count: 10
      )
      session.messages.create!(message_type: "user_message", payload: {"content" => "what happened?"}, timestamp: now_ts, token_count: 10)

      result = session.messages_for_llm(token_budget: 1000)

      # After healing, the orphaned tool_call has a synthetic tool_response
      tool_results = result.select { |m| m[:content].is_a?(Array) }
      expect(tool_results.length).to eq(2)

      response_block = tool_results.last[:content].first
      expect(response_block[:type]).to eq("tool_result")
      expect(response_block[:content]).to include("timed out")
    end
  end

  describe "#promote_pending_messages!" do
    let(:session) { Session.create! }

    context "with user messages" do
      it "persists as user_message and deletes the pending record" do
        pm = session.pending_messages.create!(content: "queued")

        session.promote_pending_messages!

        expect(PendingMessage.find_by(id: pm.id)).to be_nil
        msg = session.messages.last
        expect(msg.message_type).to eq("user_message")
        expect(msg.payload["content"]).to eq("queued")
      end

      it "returns content in :texts, nothing in :pairs" do
        session.pending_messages.create!(content: "q1")
        session.pending_messages.create!(content: "q2")

        result = session.promote_pending_messages!
        expect(result[:texts]).to eq(["q1", "q2"])
        expect(result[:pairs]).to eq([])
      end
    end

    context "with phantom pair types" do
      # Every phantom pair type must persist as tool_call + tool_response
      # in the DB (not user_message) so the TUI renders them correctly.
      {
        "subagent" => {source_name: "sleuth", tool_name: "from_sleuth"},
        "skill" => {source_name: "testing", tool_name: "from_melete_skill"},
        "workflow" => {source_name: "feature", tool_name: "from_melete_workflow"},
        "recall" => {source_name: "42", tool_name: "from_mneme"},
        "goal" => {source_name: "7", tool_name: "from_melete_goal"}
      }.each do |source_type, meta|
        context "with #{source_type} message" do
          let!(:pm) do
            session.pending_messages.create!(
              content: "test content", source_type: source_type, source_name: meta[:source_name]
            )
          end

          it "persists as tool_call + tool_response pair (not user_message)" do
            session.promote_pending_messages!

            types = session.messages.pluck(:message_type)
            expect(types).to eq(%w[tool_call tool_response])
          end

          it "sets the correct phantom tool name on both messages" do
            session.promote_pending_messages!

            call = session.messages.find_by(message_type: "tool_call")
            response = session.messages.find_by(message_type: "tool_response")
            expect(call.payload["tool_name"]).to eq(meta[:tool_name])
            expect(response.payload["tool_name"]).to eq(meta[:tool_name])
          end

          it "shares a tool_use_id between call and response" do
            session.promote_pending_messages!

            call = session.messages.find_by(message_type: "tool_call")
            response = session.messages.find_by(message_type: "tool_response")
            expect(call.tool_use_id).to be_present
            expect(call.tool_use_id).to eq(response.tool_use_id)
          end

          it "stores content in the tool_response payload" do
            session.promote_pending_messages!

            response = session.messages.find_by(message_type: "tool_response")
            expect(response.payload["content"]).to eq("test content")
          end

          it "returns phantom pairs in :pairs, nothing in :texts" do
            result = session.promote_pending_messages!
            expect(result[:texts]).to eq([])
            expect(result[:pairs].length).to eq(2)
            expect(result[:pairs][0][:role]).to eq("assistant")
            expect(result[:pairs][1][:role]).to eq("user")
          end

          it "deletes the pending record" do
            session.promote_pending_messages!

            expect(PendingMessage.find_by(id: pm.id)).to be_nil
          end
        end
      end
    end

    context "with mixed user and phantom pair messages" do
      it "persists each type correctly and splits the return value" do
        session.pending_messages.create!(content: "user says hi")
        session.pending_messages.create!(
          content: "Found a bug", source_type: "subagent", source_name: "sleuth"
        )
        session.pending_messages.create!(content: "user follows up")

        result = session.promote_pending_messages!

        expect(result[:texts]).to eq(["user says hi", "user follows up"])
        expect(result[:pairs].length).to eq(2)

        types = session.messages.pluck(:message_type)
        expect(types).to eq(%w[user_message tool_call tool_response user_message])
      end
    end

    it "generates unique tool_use_ids for multiple phantom pairs" do
      session.pending_messages.create!(
        content: "Result A", source_type: "subagent", source_name: "scout"
      )
      session.pending_messages.create!(
        content: "Result B", source_type: "subagent", source_name: "sleuth"
      )

      session.promote_pending_messages!

      tool_use_ids = session.messages.where(message_type: "tool_call").pluck(:tool_use_id)
      expect(tool_use_ids.length).to eq(2)
      expect(tool_use_ids.uniq.length).to eq(2)
    end

    it "returns empty texts and pairs when no pending messages exist" do
      result = session.promote_pending_messages!
      expect(result).to eq({texts: [], pairs: []})
    end

    it "promoted messages get IDs after existing messages" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "first"}, timestamp: 1, token_count: 10)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_A", "tool_input" => {}},
        tool_use_id: "toolu_A", timestamp: 2, token_count: 10
      )
      session.messages.create!(
        message_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_A", "content" => "ok"},
        tool_use_id: "toolu_A", timestamp: 3, token_count: 10
      )
      session.pending_messages.create!(content: "hey")

      session.promote_pending_messages!

      promoted = session.messages.reload.last
      tool_response = session.messages.where(tool_use_id: "toolu_A", message_type: "tool_response").first
      expect(promoted.id).to be > tool_response.id
      expect(promoted.payload["content"]).to eq("hey")
    end
  end

  describe "#pending_messages never interleave tool pairs" do
    let(:session) { Session.create! }

    before do
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.0)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.0)
      allow(Anima::Settings).to receive(:mneme_pinned_budget_fraction).and_return(0.0)
      allow(Anima::Settings).to receive(:recall_budget_fraction).and_return(0.0)
    end

    it "promoted messages appear after tool pairs in the LLM context" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "run bash"}, timestamp: 1, token_count: 10)
      session.messages.create!(
        message_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_A", "tool_input" => {}},
        tool_use_id: "toolu_A", timestamp: 2, token_count: 10
      )
      session.messages.create!(
        message_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_A", "content" => "ok"},
        tool_use_id: "toolu_A", timestamp: 3, token_count: 10
      )
      # Simulate promotion: pending message becomes real message AFTER tool pair
      session.pending_messages.create!(content: "hey")
      session.promote_pending_messages!

      result = session.messages_for_llm(token_budget: 1000)

      roles = result.map { |m| m[:role] }
      expect(roles).to eq(%w[user assistant user user])
      expect(result.last[:content]).to include("hey")
    end
  end

  describe "sub-agent context isolation" do
    let(:parent) { Session.create! }
    let(:child) do
      Session.create!(parent_session: parent, prompt: "sub-agent prompt")
    end

    before do
      parent.messages.create!(message_type: "user_message", payload: {"content" => "parent msg 1"}, timestamp: 1, token_count: 10)
      parent.messages.create!(message_type: "agent_message", payload: {"content" => "parent reply 1"}, timestamp: 2, token_count: 10)
    end

    it "does not include parent messages in sub-agent viewport" do
      child.messages.create!(message_type: "user_message", payload: {"content" => "child task"}, timestamp: 3, token_count: 10)

      events = child.viewport_messages
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to eq(["child task"])
    end

    it "shows only the sub-agent's own messages" do
      child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 10)
      child.messages.create!(message_type: "agent_message", payload: {"content" => "working..."}, timestamp: 4, token_count: 10)

      events = child.viewport_messages
      expect(events.map(&:session_id)).to all(eq(child.id))
    end

    it "respects token budget for sub-agent viewport" do
      child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 50)
      child.messages.create!(message_type: "agent_message", payload: {"content" => "done"}, timestamp: 4, token_count: 50)

      # Budget only fits one message
      events = child.viewport_messages(token_budget: 50)
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to eq(["done"])
    end

    it "does not inherit events from parent for main sessions" do
      main = Session.create!
      main.messages.create!(message_type: "user_message", payload: {"content" => "only mine"}, timestamp: 1, token_count: 10)

      events = main.viewport_messages
      expect(events.length).to eq(1)
      expect(events.first.payload["content"]).to eq("only mine")
    end
  end

  describe "#promote_phantom_pair!" do
    let(:session) { Session.create! }

    it "creates a tool_call and tool_response message pair" do
      pm = session.pending_messages.create!(content: "recalled text", source_type: "recall", source_name: "42")

      expect { session.promote_phantom_pair!(pm) }
        .to change { session.messages.where(message_type: "tool_call").count }.by(1)
        .and change { session.messages.where(message_type: "tool_response").count }.by(1)
    end

    it "derives tool_use_id from tool name and pending message ID" do
      pm = session.pending_messages.create!(content: "recalled text", source_type: "recall", source_name: "42")
      expected_uid = "from_mneme_#{pm.id}"

      session.promote_phantom_pair!(pm)

      call = session.messages.find_by(message_type: "tool_call")
      response = session.messages.find_by(message_type: "tool_response")
      expect(call.tool_use_id).to eq(expected_uid)
      expect(response.tool_use_id).to eq(expected_uid)
    end

    it "uses the phantom tool name from PendingMessage" do
      pm = session.pending_messages.create!(content: "goal event", source_type: "goal", source_name: "7")
      session.promote_phantom_pair!(pm)

      call = session.messages.find_by(message_type: "tool_call")
      expect(call.payload["tool_name"]).to eq("from_melete_goal")
    end

    it "stores tool input as stringified keys" do
      pm = session.pending_messages.create!(content: "goal event", source_type: "goal", source_name: "7")
      session.promote_phantom_pair!(pm)

      call = session.messages.find_by(message_type: "tool_call")
      expect(call.payload["tool_input"]).to eq("goal_id" => 7)
    end
  end

  describe "#assemble_system_prompt with snapshots" do
    let(:session) { Session.create! }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
    end

    it "includes snapshot section in the system prompt" do
      e1 = session.messages.create!(message_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 10)
      e2 = session.messages.create!(message_type: "agent_message", payload: {"content" => "reply"}, timestamp: 2, token_count: 10)
      recent = session.messages.create!(message_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 10)

      session.snapshots.create!(text: "Summary of old conversation", from_message_id: e1.id, to_message_id: e2.id, level: 1, token_count: 20)
      session.update_column(:mneme_boundary_message_id, recent.id)

      prompt = session.assemble_system_prompt
      expect(prompt).to include("Summary of old conversation")
      expect(prompt).to include("Recent Memory")
    end
  end

  describe "#initialize_mneme_boundary!" do
    subject(:initialize_boundary) { session.initialize_mneme_boundary! }

    let(:session) { create(:session) }

    context "without eligible messages" do
      it "leaves the boundary unset on an empty session" do
        expect { initialize_boundary }
          .not_to change { session.mneme_boundary_message_id }.from(nil)
      end

      it "leaves the boundary unset when only non-think tool messages exist" do
        create(:message, :bash_tool_call, session:)
        create(:message, :bash_tool_response, session:)

        expect { initialize_boundary }
          .not_to change { session.mneme_boundary_message_id }.from(nil)
      end
    end

    context "with a single eligible message" do
      it "sets the boundary to a lone conversation message" do
        message = create(:message, :user_message, session:)

        expect { initialize_boundary }
          .to change { session.mneme_boundary_message_id }
          .from(nil).to(message.id)
      end

      it "sets the boundary to a lone think tool_call" do
        thought = create(:message, :think_tool_call, session:)

        expect { initialize_boundary }
          .to change { session.mneme_boundary_message_id }
          .from(nil).to(thought.id)
      end
    end

    context "with multiple messages" do
      it "picks the oldest when a conversation message comes first" do
        first = create(:message, :user_message, session:)
        create(:message, :think_tool_call, session:)

        expect { initialize_boundary }
          .to change { session.mneme_boundary_message_id }
          .from(nil).to(first.id)
      end

      it "picks the oldest when a think tool_call comes first" do
        thought = create(:message, :think_tool_call, session:)
        create(:message, :user_message, session:)

        expect { initialize_boundary }
          .to change { session.mneme_boundary_message_id }
          .from(nil).to(thought.id)
      end

      it "skips non-think tool messages to find an eligible message" do
        create(:message, :bash_tool_call, session:)
        create(:message, :bash_tool_response, session:)
        eligible = create(:message, :user_message, session:)

        expect { initialize_boundary }
          .to change { session.mneme_boundary_message_id }
          .from(nil).to(eligible.id)
      end
    end
  end

  describe "#viewport_messages" do
    subject(:viewport) { session.viewport_messages(token_budget: budget) }

    let(:session) { create(:session) }
    let(:budget) { 100 }

    it "returns an ActiveRecord::Relation" do
      create(:message, :user_message, session:, token_count: 10)

      expect(viewport).to be_a(ActiveRecord::Relation)
    end

    it "is chainable with further AR methods" do
      m1 = create(:message, :user_message, session:, token_count: 10)
      m2 = create(:message, :user_message, session:, token_count: 10)

      expect(viewport.pluck(:id)).to eq([m1.id, m2.id])
    end

    context "when the session has no eligible messages" do
      it "returns an empty relation" do
        expect(viewport).to be_empty
      end
    end

    context "when all messages fit within the budget" do
      it "returns every message in chronological order" do
        oldest = create(:message, :user_message, session:, token_count: 20)
        middle = create(:message, :user_message, session:, token_count: 20)
        newest = create(:message, :user_message, session:, token_count: 20)

        expect(viewport.to_a).to eq([oldest, middle, newest])
      end

      it "treats every message type as eligible" do
        first = create(:message, :user_message, session:, token_count: 10)
        second = create(:message, :think_tool_call, session:, token_count: 10)
        third = create(:message, :bash_tool_call, session:, token_count: 10)
        fourth = create(:message, :bash_tool_response, session:, token_count: 10)

        expect(viewport.to_a).to eq([first, second, third, fourth])
      end
    end

    context "when cumulative cost exceeds the budget" do
      it "drops the oldest messages walking newest-first" do
        create(:message, :user_message, session:, token_count: 80)
        middle = create(:message, :user_message, session:, token_count: 60)
        newest = create(:message, :user_message, session:, token_count: 30)

        # newest=30 + middle=60 = 90 ≤ 100 → both kept
        # adding oldest (80) would push total to 170 → dropped
        expect(viewport.to_a).to eq([middle, newest])
      end

      it "includes a message whose cumulative cost exactly equals the budget" do
        oldest = create(:message, :user_message, session:, token_count: 30)
        newest = create(:message, :user_message, session:, token_count: 70)

        # newest=70 + oldest=30 = 100 ≤ 100 → both kept
        expect(viewport.to_a).to eq([oldest, newest])
      end
    end

    context "when the newest message alone exceeds the budget" do
      it "still includes the newest message and drops everything older" do
        create(:message, :user_message, session:, token_count: 50)
        newest = create(:message, :user_message, session:, token_count: 200)

        expect(viewport.to_a).to eq([newest])
      end
    end

    context "when a Mneme boundary is set" do
      it "excludes messages older than the boundary" do
        create(:message, :user_message, session:, token_count: 10)
        at_boundary = create(:message, :user_message, session:, token_count: 10)
        after_boundary = create(:message, :user_message, session:, token_count: 10)
        session.update_column(:mneme_boundary_message_id, at_boundary.id)

        expect(viewport.to_a).to eq([at_boundary, after_boundary])
      end
    end
  end

  describe "#enqueue_user_message" do
    let(:session) { Session.create! }

    context "when session is idle" do
      it "persists a deliverable event and enqueues AgentRequestJob" do
        expect { session.enqueue_user_message("hello") }
          .to change { session.messages.where(message_type: "user_message", status: nil).count }.by(1)

        expect(AgentRequestJob).to have_been_enqueued.with(session.id)
      end

      it "passes message_id to job when bounce_back is true" do
        session.enqueue_user_message("hello", bounce_back: true)

        event = session.messages.last
        expect(AgentRequestJob).to have_been_enqueued.with(session.id, message_id: event.id)
      end

      it "formats sub-agent messages with attribution" do
        session.enqueue_user_message("Found a bug", source_type: "subagent", source_name: "sleuth")

        msg = session.messages.last
        expect(msg.payload["content"]).to eq("[sub-agent sleuth]: Found a bug")
      end
    end

    context "when session is not idle" do
      before { session.start_processing! }

      it "creates a PendingMessage" do
        expect { session.enqueue_user_message("hello") }
          .to change(PendingMessage, :count).by(1)

        pm = session.pending_messages.last
        expect(pm.content).to eq("hello")
      end

      it "stores source metadata on PendingMessage" do
        session.enqueue_user_message("result", source_type: "subagent", source_name: "scout")

        pm = session.pending_messages.last
        expect(pm.source_type).to eq("subagent")
        expect(pm.source_name).to eq("scout")
      end

      it "does not enqueue AgentRequestJob" do
        session.enqueue_user_message("hello")

        expect(AgentRequestJob).not_to have_been_enqueued
      end

      it "does not persist a deliverable event" do
        session.enqueue_user_message("hello")

        expect(session.messages.where(message_type: "user_message", status: nil).count).to eq(0)
      end
    end
  end
end
