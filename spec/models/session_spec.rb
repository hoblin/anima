# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  # Computes the expected LLM content for a user message with timestamp prefix.
  # Must stay in sync with Session#format_event_time.
  def timestamped(content, timestamp_ns)
    time = Time.at(timestamp_ns / 1_000_000_000.0)
    "#{time.strftime("%a %b %-d %H:%M")}\n#{content}"
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

  describe "#next_view_mode" do
    it "cycles basic → verbose" do
      session = Session.new(view_mode: "basic")
      expect(session.next_view_mode).to eq("verbose")
    end

    it "cycles verbose → debug" do
      session = Session.new(view_mode: "verbose")
      expect(session.next_view_mode).to eq("debug")
    end

    it "cycles debug → basic" do
      session = Session.new(view_mode: "debug")
      expect(session.next_view_mode).to eq("basic")
    end
  end

  describe "associations" do
    it "has many events ordered by id" do
      session = Session.create!
      event_a = session.events.create!(event_type: "user_message", payload: {content: "first"}, timestamp: 1)
      event_b = session.events.create!(event_type: "user_message", payload: {content: "second"}, timestamp: 2)

      expect(session.events.reload).to eq([event_a, event_b])
    end

    it "destroys events when session is destroyed" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)

      expect { session.destroy }.to change(Event, :count).by(-1)
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
      child_b = Session.create!(parent_session: parent, prompt: "agent B", name: "reviewer", processing: true)

      expect(ActionCable.server).to receive(:broadcast).with(
        "session_#{parent.id}",
        {
          "action" => "children_updated",
          "session_id" => parent.id,
          "children" => [
            {"id" => child_a.id, "name" => "analyzer", "processing" => false},
            {"id" => child_b.id, "name" => "reviewer", "processing" => true}
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
      expect(child_data.keys).to contain_exactly("id", "name", "processing")
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

  describe "#schedule_analytical_brain!" do
    it "enqueues AnalyticalBrainJob for unnamed root sessions with messages" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { session.schedule_analytical_brain! }
        .to have_enqueued_job(AnalyticalBrainJob).with(session.id)
    end

    it "does not enqueue for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")
      child.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      child.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { child.schedule_analytical_brain! }
        .not_to have_enqueued_job(AnalyticalBrainJob)
    end

    it "does not enqueue for sessions with fewer than 2 messages" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)

      expect { session.schedule_analytical_brain! }
        .not_to have_enqueued_job(AnalyticalBrainJob)
    end

    it "enqueues at name_generation_interval for named sessions" do
      session = Session.create!(name: "Old Name")
      Anima::Settings.name_generation_interval.times do |i|
        type = i.even? ? "user_message" : "agent_message"
        session.events.create!(event_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
      end

      expect { session.schedule_analytical_brain! }
        .to have_enqueued_job(AnalyticalBrainJob).with(session.id)
    end

    it "does not enqueue for named sessions between intervals" do
      session = Session.create!(name: "Existing")
      3.times do |i|
        type = i.even? ? "user_message" : "agent_message"
        session.events.create!(event_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
      end

      expect { session.schedule_analytical_brain! }
        .not_to have_enqueued_job(AnalyticalBrainJob)
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

  describe "#broadcast_active_skills_update" do
    it "broadcasts active skills change to the session stream" do
      session = Session.create!

      expect {
        session.update!(active_skills: ["gh-issue", "activerecord"])
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "active_skills_updated",
          "session_id" => session.id,
          "active_skills" => ["gh-issue", "activerecord"]
        ))
    end

    it "does not broadcast when active_skills is unchanged" do
      session = Session.create!(active_skills: ["gh-issue"])

      expect {
        session.update!(name: "New Name")
      }.not_to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_skills_updated"))
    end
  end

  describe "#granted_tools" do
    it "returns nil when not set" do
      session = Session.create!
      expect(session.granted_tools).to be_nil
    end

    it "round-trips an array of tool names through JSON serialization" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "agent", granted_tools: ["read", "web_get"])

      expect(child.reload.granted_tools).to eq(["read", "web_get"])
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

  describe "#system_prompt" do
    before { Skills::Registry.reload! }

    it "returns prompt for sub-agent sessions (bypasses soul)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")

      expect(child.system_prompt).to eq("You are a research assistant.")
    end

    it "ignores environment_context for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")

      expect(child.system_prompt(environment_context: "## Environment\n\nOS: Linux"))
        .to eq("You are a research assistant.")
    end

    it "includes soul content for main sessions" do
      session = Session.create!

      expect(session.system_prompt).to include("# Soul")
    end

    it "places soul before expertise in the system prompt" do
      session = Session.create!
      session.activate_skill("gh-issue")

      prompt = session.system_prompt
      soul_pos = prompt.index("# Soul")
      expertise_pos = prompt.index("## Your Expertise")
      expect(soul_pos).to be < expertise_pos
    end

    it "includes environment context between soul and expertise" do
      session = Session.create!
      session.activate_skill("gh-issue")
      env = "## Environment\n\nOS: Arch Linux (pacman, yay)\nCWD: /home/user/project"

      prompt = session.system_prompt(environment_context: env)
      soul_pos = prompt.index("# Soul")
      env_pos = prompt.index("## Environment")
      expertise_pos = prompt.index("## Your Expertise")
      expect(soul_pos).to be < env_pos
      expect(env_pos).to be < expertise_pos
    end

    it "includes environment context between soul and goals when no expertise" do
      session = Session.create!
      Goal.create!(session: session, description: "Test goal")
      env = "## Environment\n\nOS: Linux"

      prompt = session.system_prompt(environment_context: env)
      soul_pos = prompt.index("# Soul")
      env_pos = prompt.index("## Environment")
      goals_pos = prompt.index("## Current Goals")
      expect(soul_pos).to be < env_pos
      expect(env_pos).to be < goals_pos
    end

    it "works without environment context" do
      session = Session.create!

      prompt = session.system_prompt
      expect(prompt).to start_with("# Soul")
      expect(prompt).not_to include("## Environment")
    end
  end

  describe "#activate_skill" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "adds the skill to active_skills" do
      session.activate_skill("gh-issue")

      expect(session.reload.active_skills).to eq(["gh-issue"])
    end

    it "returns the skill definition" do
      result = session.activate_skill("gh-issue")

      expect(result).to be_a(Skills::Definition)
      expect(result.name).to eq("gh-issue")
    end

    it "raises for unknown skills" do
      expect { session.activate_skill("nonexistent") }
        .to raise_error(Skills::InvalidDefinitionError, /Unknown skill/)
    end

    it "is idempotent — does not duplicate" do
      session.activate_skill("gh-issue")
      session.activate_skill("gh-issue")

      expect(session.reload.active_skills).to eq(["gh-issue"])
    end

    it "persists to the database" do
      session.activate_skill("gh-issue")

      reloaded = Session.find(session.id)
      expect(reloaded.active_skills).to eq(["gh-issue"])
    end
  end

  describe "#deactivate_skill" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "removes the skill from active_skills" do
      session.activate_skill("gh-issue")
      session.deactivate_skill("gh-issue")

      expect(session.reload.active_skills).to be_empty
    end

    it "is safe when skill is not active" do
      expect { session.deactivate_skill("nonexistent") }.not_to raise_error
    end

    it "persists to the database" do
      session.activate_skill("gh-issue")
      session.deactivate_skill("gh-issue")

      reloaded = Session.find(session.id)
      expect(reloaded.active_skills).to be_empty
    end
  end

  describe "#assemble_system_prompt" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "always starts with the soul" do
      expect(session.assemble_system_prompt).to start_with("# Soul")
    end

    it "includes Your Expertise header when skills are active" do
      session.activate_skill("gh-issue")

      expect(session.assemble_system_prompt).to include("## Your Expertise")
    end

    it "includes full skill content" do
      session.activate_skill("gh-issue")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("WHAT/WHY/HOW")
      expect(prompt).to include("Quality Checklist")
    end

    it "uses the first heading from skill content as section title" do
      session.activate_skill("gh-issue")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### GitHub Issue Writing")
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

        stub_const("Skills::Registry::USER_DIR", tmp_dir)
        Skills::Registry.reload!
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it "assembles all active skills into the system prompt" do
        session.activate_skill("gh-issue")
        session.activate_skill("testing")

        prompt = session.assemble_system_prompt
        expect(prompt).to include("### GitHub Issue Writing")
        expect(prompt).to include("### Testing Guide")
      end

      it "preserves activation order" do
        session.activate_skill("testing")
        session.activate_skill("gh-issue")

        expect(session.reload.active_skills).to eq(%w[testing gh-issue])
      end

      it "deactivates one skill while others remain active" do
        session.activate_skill("gh-issue")
        session.activate_skill("testing")
        session.deactivate_skill("gh-issue")

        expect(session.reload.active_skills).to eq(["testing"])
        prompt = session.assemble_system_prompt
        expect(prompt).to include("### Testing Guide")
        expect(prompt).not_to include("GitHub Issue Writing")
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
      goal = Goal.create!(session: session, description: "test goal")

      expect(session.goals).to eq([goal])
    end

    it "destroys goals when session is destroyed" do
      session = Session.create!
      Goal.create!(session: session, description: "doomed")

      expect { session.destroy }.to change(Goal, :count).by(-1)
    end
  end

  describe "#goals_summary" do
    let(:session) { Session.create! }

    it "returns empty array when no goals exist" do
      expect(session.goals_summary).to eq([])
    end

    it "returns root goals with their sub-goals" do
      root = Goal.create!(session: session, description: "Implement auth")
      Goal.create!(session: session, parent_goal: root, description: "Read code")
      Goal.create!(session: session, parent_goal: root, description: "Write tests", status: "completed")

      summary = session.goals_summary
      expect(summary.size).to eq(1)
      expect(summary.first["description"]).to eq("Implement auth")
      expect(summary.first["status"]).to eq("active")
      expect(summary.first["sub_goals"].size).to eq(2)
      expect(summary.first["sub_goals"].first["description"]).to eq("Read code")
      expect(summary.first["sub_goals"].last["status"]).to eq("completed")
    end

    it "excludes sub-goals from root level" do
      root = Goal.create!(session: session, description: "root")
      Goal.create!(session: session, parent_goal: root, description: "child")

      summary = session.goals_summary
      expect(summary.size).to eq(1)
      expect(summary.first["description"]).to eq("root")
    end

    it "orders root goals by created_at" do
      first = Goal.create!(session: session, description: "first")
      second = Goal.create!(session: session, description: "second")

      summary = session.goals_summary
      expect(summary.map { |g| g["id"] }).to eq([first.id, second.id])
    end
  end

  describe "#assemble_system_prompt with goals" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "includes soul and goals when goals exist but no skills" do
      Goal.create!(session: session, description: "Implement feature")

      prompt = session.assemble_system_prompt
      expect(prompt).to start_with("# Soul")
      expect(prompt).to include("## Current Goals")
      expect(prompt).to include("### Implement feature")
      expect(prompt).not_to include("Your Expertise")
    end

    it "includes all sections when skills and goals are present" do
      session.activate_skill("gh-issue")
      Goal.create!(session: session, description: "Write ticket")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("## Your Expertise")
      expect(prompt).to include("## Current Goals")
    end

    it "renders sub-goals as checkbox items" do
      root = Goal.create!(session: session, description: "Refactor auth")
      Goal.create!(session: session, parent_goal: root, description: "Read existing code", status: "completed")
      Goal.create!(session: session, parent_goal: root, description: "Write new middleware")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### Refactor auth")
      expect(prompt).to include("- [x] Read existing code")
      expect(prompt).to include("- [ ] Write new middleware")
    end

    it "renders multiple root goals" do
      Goal.create!(session: session, description: "First goal")
      Goal.create!(session: session, description: "Second goal")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### First goal")
      expect(prompt).to include("### Second goal")
    end

    it "renders completed root goals with strikethrough" do
      Goal.create!(session: session, description: "Set up CI", status: "completed", completed_at: 1.hour.ago)

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### ~~Set up CI~~ ✓")
    end

    it "hides sub-goals of completed root goals" do
      root = Goal.create!(session: session, description: "Done task", status: "completed", completed_at: 1.hour.ago)
      Goal.create!(session: session, parent_goal: root, description: "Hidden sub-goal", status: "completed", completed_at: 1.hour.ago)

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### ~~Done task~~ ✓")
      expect(prompt).not_to include("Hidden sub-goal")
    end

    it "renders active and completed root goals together" do
      Goal.create!(session: session, description: "Completed task", status: "completed", completed_at: 1.hour.ago)
      root = Goal.create!(session: session, description: "Active task")
      Goal.create!(session: session, parent_goal: root, description: "Step 1")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### ~~Completed task~~ ✓")
      expect(prompt).to include("### Active task")
      expect(prompt).to include("- [ ] Step 1")
    end
  end

  describe "#activate_workflow" do
    before { Workflows::Registry.reload! }

    let(:session) { Session.create! }

    it "sets the workflow as active" do
      session.activate_workflow("feature")

      expect(session.reload.active_workflow).to eq("feature")
    end

    it "returns the workflow definition" do
      result = session.activate_workflow("feature")

      expect(result).to be_a(Workflows::Definition)
      expect(result.name).to eq("feature")
    end

    it "raises for unknown workflows" do
      expect { session.activate_workflow("nonexistent") }
        .to raise_error(Workflows::InvalidDefinitionError, /Unknown workflow/)
    end

    it "is idempotent — returns definition without re-saving" do
      session.activate_workflow("feature")
      result = session.activate_workflow("feature")

      expect(result).to be_a(Workflows::Definition)
      expect(session.reload.active_workflow).to eq("feature")
    end

    it "replaces the previous active workflow" do
      session.activate_workflow("feature")
      session.activate_workflow("commit")

      expect(session.reload.active_workflow).to eq("commit")
    end

    it "persists to the database" do
      session.activate_workflow("feature")

      reloaded = Session.find(session.id)
      expect(reloaded.active_workflow).to eq("feature")
    end
  end

  describe "#deactivate_workflow" do
    before { Workflows::Registry.reload! }

    let(:session) { Session.create! }

    it "clears the active workflow" do
      session.activate_workflow("feature")
      session.deactivate_workflow

      expect(session.reload.active_workflow).to be_nil
    end

    it "is safe when no workflow is active" do
      expect { session.deactivate_workflow }.not_to raise_error
    end

    it "persists to the database" do
      session.activate_workflow("feature")
      session.deactivate_workflow

      reloaded = Session.find(session.id)
      expect(reloaded.active_workflow).to be_nil
    end
  end

  describe "#broadcast_active_workflow_update" do
    it "broadcasts active workflow change to the session stream" do
      session = Session.create!

      expect {
        session.update!(active_workflow: "feature")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "active_workflow_updated",
          "session_id" => session.id,
          "active_workflow" => "feature"
        ))
    end

    it "does not broadcast when active_workflow is unchanged" do
      session = Session.create!(active_workflow: "feature")

      expect {
        session.update!(name: "New Name")
      }.not_to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_workflow_updated"))
    end
  end

  describe "#assemble_system_prompt with workflows" do
    before do
      Skills::Registry.reload!
      Workflows::Registry.reload!
    end

    let(:session) { Session.create! }

    it "includes workflow content in Your Expertise section" do
      session.activate_workflow("feature")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("## Your Expertise")
      expect(prompt).to include("branch creation to PR readiness")
    end

    it "includes both skills and workflow content" do
      session.activate_skill("gh-issue")
      session.activate_workflow("feature")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### GitHub Issue Writing")
      expect(prompt).to include("branch creation to PR readiness")
    end

    it "returns only soul when neither skills nor workflow nor goals are present" do
      expect(session.assemble_system_prompt).to start_with("# Soul")
    end
  end

  describe "#messages_for_llm" do
    let(:session) { Session.create! }

    it "returns user_message events with user role and timestamp prefix" do
      session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "user", content: timestamped("hello", 1)}])
    end

    it "returns agent_message events with assistant role" do
      session.events.create!(event_type: "agent_message", payload: {"content" => "hi there"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "assistant", content: "hi there"}])
    end

    it "includes system_message events as user role with [system] prefix" do
      session.events.create!(event_type: "system_message", payload: {"content" => "MCP: server failed"}, timestamp: 1)

      messages = session.messages_for_llm
      expect(messages.size).to eq(1)
      expect(messages.first[:role]).to eq("user")
      expect(messages.first[:content]).to eq("[system] MCP: server failed")
    end

    context "with tool events" do
      it "assembles tool_call events as assistant messages with tool_use blocks" do
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_123"},
          timestamp: 1
        )

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "assistant", content: [
            {type: "tool_use", id: "toolu_123", name: "web_get", input: {"url" => "https://example.com"}}
          ]}
        ])
      end

      it "assembles tool_response events as user messages with tool_result blocks" do
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "<html>hello</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_123", "success" => true},
          timestamp: 1
        )

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "user", content: [
            {type: "tool_result", tool_use_id: "toolu_123", content: "<html>hello</html>"}
          ]}
        ])
      end

      it "groups consecutive tool_call events into one assistant message" do
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://a.com"}, "tool_use_id" => "toolu_1"},
          timestamp: 1
        )
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://b.com"}, "tool_use_id" => "toolu_2"},
          timestamp: 2
        )

        result = session.messages_for_llm
        expect(result.length).to eq(1)
        expect(result.first[:role]).to eq("assistant")
        expect(result.first[:content].length).to eq(2)
      end

      it "groups consecutive tool_response events into one user message" do
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "page A", "tool_name" => "web_get", "tool_use_id" => "toolu_1"},
          timestamp: 1
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "page B", "tool_name" => "web_get", "tool_use_id" => "toolu_2"},
          timestamp: 2
        )

        result = session.messages_for_llm
        expect(result.length).to eq(1)
        expect(result.first[:role]).to eq("user")
        expect(result.first[:content].length).to eq(2)
      end

      it "assembles a full tool conversation correctly" do
        session.events.create!(event_type: "user_message", payload: {"content" => "what is on example.com?"}, timestamp: 1)
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_abc"},
          timestamp: 2
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "<html>Example Domain</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_abc", "success" => true},
          timestamp: 3
        )
        session.events.create!(event_type: "agent_message", payload: {"content" => "The page says Example Domain."}, timestamp: 4)

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

    it "preserves event order" do
      session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "second"}, timestamp: 2)
      session.events.create!(event_type: "user_message", payload: {"content" => "third"}, timestamp: 3)

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
        session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2, token_count: 10)

        expect(session.messages_for_llm(token_budget: 100)).to eq([
          {role: "user", content: timestamped("hi", 1)},
          {role: "assistant", content: "hello"}
        ])
      end

      it "drops oldest events when budget exceeded" do
        session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 50)
        session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 50)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 50)
        session.events.create!(event_type: "agent_message", payload: {"content" => "recent reply"}, timestamp: 4, token_count: 50)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([
          {role: "user", content: timestamped("recent", 3)},
          {role: "assistant", content: "recent reply"}
        ])
      end

      it "always includes at least the newest event even if it exceeds budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "big message"}, timestamp: 1, token_count: 500)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([{role: "user", content: timestamped("big message", 1)}])
      end

      it "uses heuristic estimate for events with zero token_count" do
        session.events.create!(event_type: "user_message", payload: {"content" => "x" * 400}, timestamp: 1, token_count: 0)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        # "x" * 400 => ~100 token estimate, plus 10 = 110, fits in 200
        result = session.messages_for_llm(token_budget: 200)
        expect(result.length).to eq(2)
      end

      it "returns events in chronological order" do
        session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "second"}, timestamp: 2, token_count: 10)
        session.events.create!(event_type: "user_message", payload: {"content" => "third"}, timestamp: 3, token_count: 10)

        result = session.messages_for_llm(token_budget: 30)

        expect(result.map { |m| m[:content] }).to eq([timestamped("first", 1), "second", timestamped("third", 3)])
      end
    end

    context "with snapshots" do
      let(:session) { Session.create! }

      before do
        allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
        allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
      end

      # Creates events and returns a snapshot whose source events are BEFORE
      # the viewport (to_event_id < first viewport event).
      def create_viewport_with_evicted_snapshot(session, budget:)
        # Old events that will be evicted by budget pressure
        e1 = session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: budget)
        e2 = session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: budget)
        # Recent event that fills the viewport
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 10)

        # Snapshot covers the old events (contiguous range)
        session.snapshots.create!(
          text: "Earlier discussion summary",
          from_event_id: e1.id, to_event_id: e2.id,
          level: 1, token_count: 20
        )
      end

      it "includes L1 snapshots above sliding window events" do
        create_viewport_with_evicted_snapshot(session, budget: 1000)

        # Budget tight enough that old events evict, leaving snapshot visible
        result = session.messages_for_llm(token_budget: 100)

        expect(result.first[:content]).to include("[recent memory]")
        expect(result.first[:content]).to include("Earlier discussion summary")
      end

      it "excludes snapshots whose source events are still in the viewport" do
        e1 = session.events.create!(event_type: "user_message", payload: {"content" => "visible"}, timestamp: 1, token_count: 10)
        e2 = session.events.create!(event_type: "agent_message", payload: {"content" => "reply"}, timestamp: 2, token_count: 10)

        # Snapshot covers events still in the viewport
        session.snapshots.create!(text: "Should not appear", from_event_id: e1.id, to_event_id: e2.id, level: 1, token_count: 20)

        result = session.messages_for_llm(token_budget: 1000)

        contents = result.map { |m| m[:content] }
        expect(contents.none? { |c| c.include?("Should not appear") }).to be true
      end

      it "places L2 snapshots above L1 snapshots in message order" do
        # Create old events that will evict, then a recent one that stays
        e1 = session.events.create!(event_type: "user_message", payload: {"content" => "old1"}, timestamp: 1, token_count: 500)
        e2 = session.events.create!(event_type: "agent_message", payload: {"content" => "old2"}, timestamp: 2, token_count: 500)
        e3 = session.events.create!(event_type: "user_message", payload: {"content" => "old3"}, timestamp: 3, token_count: 500)
        e4 = session.events.create!(event_type: "agent_message", payload: {"content" => "old4"}, timestamp: 4, token_count: 500)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 5, token_count: 10)

        # L2 covers first two events, L1 covers next two (not covered by L2)
        session.snapshots.create!(text: "L2 meta-summary", from_event_id: e1.id, to_event_id: e2.id, level: 2, token_count: 20)
        session.snapshots.create!(text: "L1 uncovered", from_event_id: e3.id, to_event_id: e4.id, level: 1, token_count: 20)

        # Budget tight so old events evict, making snapshots visible
        result = session.messages_for_llm(token_budget: 100)

        memory_messages = result.select { |m| m[:content].is_a?(String) && m[:content].start_with?("[") }
        labels = memory_messages.map { |m| m[:content].lines.first.strip }
        expect(labels).to eq(["[long-term memory]", "[recent memory]"])
      end

      it "drops L1 snapshots covered by L2" do
        # Create old events, then a recent one
        e1 = session.events.create!(event_type: "user_message", payload: {"content" => "old1"}, timestamp: 1, token_count: 500)
        e2 = session.events.create!(event_type: "agent_message", payload: {"content" => "old2"}, timestamp: 2, token_count: 500)
        e3 = session.events.create!(event_type: "user_message", payload: {"content" => "old3"}, timestamp: 3, token_count: 500)
        e4 = session.events.create!(event_type: "agent_message", payload: {"content" => "old4"}, timestamp: 4, token_count: 500)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 5, token_count: 10)

        # L1(e1..e2), L1(e3..e4) — both covered by L2(e1..e4)
        session.snapshots.create!(text: "L1 covered a", from_event_id: e1.id, to_event_id: e2.id, level: 1, token_count: 20)
        session.snapshots.create!(text: "L1 covered b", from_event_id: e3.id, to_event_id: e4.id, level: 1, token_count: 20)
        session.snapshots.create!(text: "L2 covers both", from_event_id: e1.id, to_event_id: e4.id, level: 2, token_count: 30)

        result = session.messages_for_llm(token_budget: 100)

        contents = result.map { |m| m[:content] }
        expect(contents.any? { |c| c.include?("L2 covers both") }).to be true
        expect(contents.none? { |c| c.include?("L1 covered") }).to be true
      end

      it "skips snapshot injection for sub-agent sessions" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 1, token_count: 10)

        # Parent has a snapshot — child should not see it
        parent.snapshots.create!(text: "Parent snapshot", from_event_id: 1, to_event_id: 5, level: 1, token_count: 20)

        result = child.messages_for_llm(token_budget: 1000)

        contents = result.map { |m| m[:content] }
        expect(contents.none? { |c| c.include?("Parent snapshot") }).to be true
      end

      it "reduces sliding window budget by snapshot and pinned budget fractions" do
        # Budget 1000, l1_fraction=0.15, l2_fraction=0.05, pinned_fraction=0.05
        # Sliding budget = 1000 - 150 - 50 - 50 = 750
        session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 500)
        session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 500)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 500)

        result = session.messages_for_llm(token_budget: 1000)

        # With 750 token sliding budget: only newest event fits (500 < 750, next 500 exceeds remaining 250)
        event_contents = result.reject { |m| m[:content].to_s.start_with?("[") }.map { |m| m[:content] }
        expect(event_contents.size).to eq(1)
      end
    end

    context "with pinned events" do
      let(:session) { Session.create! }

      before do
        allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
        allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
        allow(Anima::Settings).to receive(:mneme_pinned_budget_fraction).and_return(0.05)
      end

      it "includes pinned events after snapshots and before sliding window" do
        old_event = session.events.create!(event_type: "user_message", payload: {"content" => "critical instruction"}, timestamp: 1, token_count: 500)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        goal = session.goals.create!(description: "Active goal")
        pin = PinnedEvent.create!(event: old_event, display_text: "critical instruction")
        GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

        result = session.messages_for_llm(token_budget: 100)

        pinned_msg = result.find { |m| m[:content].to_s.include?("[pinned events]") }
        expect(pinned_msg).to be_present
        expect(pinned_msg[:content]).to include("critical instruction")
        expect(pinned_msg[:content]).to include("Active goal")
      end

      it "excludes pinned events whose source events are still in the viewport" do
        event = session.events.create!(event_type: "user_message", payload: {"content" => "visible"}, timestamp: 1, token_count: 10)

        goal = session.goals.create!(description: "Goal")
        pin = PinnedEvent.create!(event: event, display_text: "visible")
        GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

        result = session.messages_for_llm(token_budget: 1000)

        contents = result.map { |m| m[:content] }
        expect(contents.none? { |c| c.include?("[pinned events]") }).to be true
      end

      it "deduplicates pinned events across goals — first shows text, second shows bare ID" do
        old_event = session.events.create!(event_type: "user_message", payload: {"content" => "shared"}, timestamp: 1, token_count: 500)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        goal_a = session.goals.create!(description: "Goal A")
        goal_b = session.goals.create!(description: "Goal B")
        pin = PinnedEvent.create!(event: old_event, display_text: "shared")
        GoalPinnedEvent.create!(goal: goal_a, pinned_event: pin)
        GoalPinnedEvent.create!(goal: goal_b, pinned_event: pin)

        result = session.messages_for_llm(token_budget: 100)

        pinned_content = result.find { |m| m[:content].to_s.include?("[pinned events]") }&.dig(:content)
        expect(pinned_content).to be_present
        # First goal shows text, second shows bare ID
        expect(pinned_content).to include("event #{old_event.id}: shared")
        expect(pinned_content).to match(/event #{old_event.id}\n|event #{old_event.id}$/)
      end

      it "skips pinned events for sub-agent sessions" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        old_event = parent.events.create!(event_type: "user_message", payload: {"content" => "pinned"}, timestamp: 1, token_count: 10)
        child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 2, token_count: 10)

        goal = parent.goals.create!(description: "Goal")
        pin = PinnedEvent.create!(event: old_event, display_text: "pinned")
        GoalPinnedEvent.create!(goal: goal, pinned_event: pin)

        result = child.messages_for_llm(token_budget: 1000)

        contents = result.map { |m| m[:content] }
        expect(contents.none? { |c| c.include?("[pinned events]") }).to be true
      end
    end
  end

  describe "#heal_orphaned_tool_calls!" do
    let(:session) { Session.create! }

    it "creates synthetic responses for expired tool_calls without matching tool_response" do
      expired_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (200 * 1_000_000_000)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_orphan", "timeout" => 180},
        tool_use_id: "toolu_orphan",
        timestamp: expired_ts
      )

      expect { session.heal_orphaned_tool_calls! }.to change { session.events.where(event_type: "tool_response").count }.by(1)

      response = session.events.find_by(event_type: "tool_response", tool_use_id: "toolu_orphan")
      expect(response.payload["success"]).to be false
      expect(response.payload["content"]).to include("timed out")
      expect(response.payload["tool_name"]).to eq("bash")
    end

    it "does not heal tool_calls still within their timeout window" do
      recent_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (10 * 1_000_000_000)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_fresh", "timeout" => 180},
        tool_use_id: "toolu_fresh",
        timestamp: recent_ts
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.events.count }
    end

    it "respects per-call timeout override from the agent" do
      called_5_min_ago = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (300 * 1_000_000_000)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_long", "timeout" => 600},
        tool_use_id: "toolu_long",
        timestamp: called_5_min_ago
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.events.count }
    end

    it "does not create responses for tool_calls that already have one" do
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_ok"},
        tool_use_id: "toolu_ok",
        timestamp: 1
      )
      session.events.create!(
        event_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_ok", "content" => "output"},
        tool_use_id: "toolu_ok",
        timestamp: 2
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.events.count }
    end

    it "ignores tool_calls with nil tool_use_id" do
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash"},
        tool_use_id: nil,
        timestamp: 1
      )

      expect { session.heal_orphaned_tool_calls! }.not_to change { session.events.count }
    end

    it "heals multiple orphaned tool_calls in a single pass" do
      expired_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (200 * 1_000_000_000)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_a", "timeout" => 180},
        tool_use_id: "toolu_a",
        timestamp: expired_ts
      )
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "web_get", "tool_use_id" => "toolu_b", "timeout" => 60},
        tool_use_id: "toolu_b",
        timestamp: expired_ts
      )

      expect(session.heal_orphaned_tool_calls!).to eq(2)

      expect(session.events.where(event_type: "tool_response", tool_use_id: "toolu_a")).to exist
      expect(session.events.where(event_type: "tool_response", tool_use_id: "toolu_b")).to exist
    end

    it "falls back to Settings.tool_timeout when payload has no timeout key" do
      allow(Anima::Settings).to receive(:tool_timeout).and_return(60)
      expired_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (90 * 1_000_000_000)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_no_timeout"},
        tool_use_id: "toolu_no_timeout",
        timestamp: expired_ts
      )

      expect { session.heal_orphaned_tool_calls! }.to change { session.events.where(event_type: "tool_response").count }.by(1)

      response = session.events.find_by(event_type: "tool_response", tool_use_id: "toolu_no_timeout")
      expect(response.payload["content"]).to include("60 seconds")
    end

    it "is idempotent — second call creates no duplicates" do
      expired_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (200 * 1_000_000_000)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_orphan", "timeout" => 180},
        tool_use_id: "toolu_orphan",
        timestamp: expired_ts
      )

      session.heal_orphaned_tool_calls!
      expect { session.heal_orphaned_tool_calls! }.not_to change { session.events.count }
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
      session.events.create!(event_type: "user_message", payload: {"content" => "go"}, timestamp: 1, token_count: 10)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_cut", "tool_input" => {}},
        tool_use_id: "toolu_cut",
        timestamp: 2,
        token_count: 10
      )
      session.events.create!(
        event_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_cut", "content" => "ok"},
        tool_use_id: "toolu_cut",
        timestamp: 3,
        token_count: 10
      )
      session.events.create!(event_type: "agent_message", payload: {"content" => "done"}, timestamp: 4, token_count: 10)
      session.events.create!(event_type: "user_message", payload: {"content" => "more"}, timestamp: 5, token_count: 10)

      # Budget fits newest 3 events but cuts the tool_call (event 2).
      # tool_response (event 3) would be orphaned without atomic pair enforcement.
      result = session.messages_for_llm(token_budget: 30)

      tool_results = result.select { |m| m[:content].is_a?(Array) }
      expect(tool_results).to be_empty
    end

    it "keeps complete tool pairs within the viewport" do
      session.events.create!(event_type: "user_message", payload: {"content" => "go"}, timestamp: 1, token_count: 10)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_1", "tool_input" => {}},
        tool_use_id: "toolu_1",
        timestamp: 2,
        token_count: 10
      )
      session.events.create!(
        event_type: "tool_response",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_1", "content" => "ok"},
        tool_use_id: "toolu_1",
        timestamp: 3,
        token_count: 10
      )
      session.events.create!(event_type: "agent_message", payload: {"content" => "done"}, timestamp: 4, token_count: 10)

      result = session.messages_for_llm(token_budget: 40)

      tool_results = result.select { |m| m[:content].is_a?(Array) }
      expect(tool_results.length).to eq(2)
    end

    it "heals expired orphaned tool_calls before assembling messages" do
      expired_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - (200 * 1_000_000_000)
      now_ts = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_use_id" => "toolu_dead", "tool_input" => {}, "timeout" => 180},
        tool_use_id: "toolu_dead",
        timestamp: expired_ts,
        token_count: 10
      )
      session.events.create!(event_type: "user_message", payload: {"content" => "what happened?"}, timestamp: now_ts, token_count: 10)

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

    it "promotes pending user messages to delivered (nil status)" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"content" => "queued", "status" => "pending"},
        timestamp: 1,
        status: "pending"
      )

      session.promote_pending_messages!

      event.reload
      expect(event.status).to be_nil
      expect(event.payload).not_to have_key("status")
    end

    it "returns the count of promoted messages" do
      session.events.create!(event_type: "user_message", payload: {"content" => "q1", "status" => "pending"}, timestamp: 1, status: "pending")
      session.events.create!(event_type: "user_message", payload: {"content" => "q2", "status" => "pending"}, timestamp: 2, status: "pending")

      expect(session.promote_pending_messages!).to eq(2)
    end

    it "returns zero when no pending messages exist" do
      session.events.create!(event_type: "user_message", payload: {"content" => "done"}, timestamp: 1)

      expect(session.promote_pending_messages!).to eq(0)
    end

    it "does not affect non-pending events" do
      delivered = session.events.create!(event_type: "user_message", payload: {"content" => "done"}, timestamp: 1)
      session.events.create!(event_type: "user_message", payload: {"content" => "q", "status" => "pending"}, timestamp: 2, status: "pending")

      session.promote_pending_messages!

      expect(delivered.reload.status).to be_nil
    end
  end

  describe "#messages_for_llm with pending messages" do
    let(:session) { Session.create! }

    it "excludes pending messages from LLM context" do
      session.events.create!(event_type: "user_message", payload: {"content" => "delivered"}, timestamp: 1)
      session.events.create!(event_type: "user_message", payload: {"content" => "queued", "status" => "pending"}, timestamp: 2, status: "pending")

      result = session.messages_for_llm
      expect(result).to eq([{role: "user", content: timestamped("delivered", 1)}])
    end
  end

  describe "#viewport_events with pending messages" do
    let(:session) { Session.create! }

    it "includes pending messages by default (for display)" do
      session.events.create!(event_type: "user_message", payload: {"content" => "delivered"}, timestamp: 1, token_count: 10)
      session.events.create!(event_type: "user_message", payload: {"content" => "queued"}, timestamp: 2, status: "pending", token_count: 10)

      events = session.viewport_events
      expect(events.map { |e| e.payload["content"] }).to eq(%w[delivered queued])
    end

    it "excludes pending messages when include_pending is false" do
      session.events.create!(event_type: "user_message", payload: {"content" => "delivered"}, timestamp: 1, token_count: 10)
      session.events.create!(event_type: "user_message", payload: {"content" => "queued"}, timestamp: 2, status: "pending", token_count: 10)

      events = session.viewport_events(include_pending: false)
      expect(events.map { |e| e.payload["content"] }).to eq(%w[delivered])
    end
  end

  describe "virtual viewport inheritance" do
    let(:parent) { Session.create! }
    let(:child) do
      # Ensure parent events have earlier created_at
      Session.create!(parent_session: parent, prompt: "sub-agent prompt")
    end

    before do
      # Parent conversation history (created before child session)
      parent.events.create!(event_type: "user_message", payload: {"content" => "parent msg 1"}, timestamp: 1, token_count: 10)
      parent.events.create!(event_type: "agent_message", payload: {"content" => "parent reply 1"}, timestamp: 2, token_count: 10)
    end

    it "includes parent events before child events for sub-agent sessions" do
      child.events.create!(event_type: "user_message", payload: {"content" => "child task"}, timestamp: 3, token_count: 10)

      events = child.viewport_events
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to eq(["parent msg 1", "parent reply 1", "child task"])
    end

    it "shows parent events first chronologically, then child events" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 10)
      child.events.create!(event_type: "agent_message", payload: {"content" => "working..."}, timestamp: 4, token_count: 10)

      events = child.viewport_events
      sessions = events.map(&:session_id)

      # Parent events come first, then child events
      parent_indices = sessions.each_index.select { |i| sessions[i] == parent.id }
      child_indices = sessions.each_index.select { |i| sessions[i] == child.id }
      expect(parent_indices.max).to be < child_indices.min
    end

    it "respects token budget for combined viewport" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 50)

      # Budget of 60: child event (50) + one parent event (10), but not both parent events (20)
      events = child.viewport_events(token_budget: 60)
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to include("task")
      expect(contents.length).to eq(2) # child + 1 parent event
    end

    it "prioritizes child events over parent events" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 50)

      # Budget only fits the child event
      events = child.viewport_events(token_budget: 50)
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to eq(["task"])
    end

    it "does not inherit events from parent for main sessions" do
      main = Session.create!
      main.events.create!(event_type: "user_message", payload: {"content" => "only mine"}, timestamp: 1, token_count: 10)

      events = main.viewport_events
      expect(events.length).to eq(1)
      expect(events.first.payload["content"]).to eq("only mine")
    end

    it "excludes parent events created after the child session" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 10)

      # Parent event with created_at well after child — should not be inherited
      parent.events.create!(
        event_type: "agent_message",
        payload: {"content" => "parent continues"},
        timestamp: 4, token_count: 10,
        created_at: child.created_at + 1.second
      )

      events = child.viewport_events
      contents = events.map { |e| e.payload["content"] }

      expect(contents).not_to include("parent continues")
    end

    it "excludes spawn tool events from parent context" do
      # Sibling spawn events should not appear in sub-agent's viewport
      parent.events.create!(
        event_type: "tool_call",
        payload: {"content" => "Calling spawn_specialist", "tool_name" => "spawn_specialist",
                  "tool_input" => {"name" => "codebase-analyzer"}, "tool_use_id" => "toolu_sibling"},
        timestamp: 3, token_count: 10
      )
      parent.events.create!(
        event_type: "tool_response",
        payload: {"content" => "Specialist @sibling spawned", "tool_name" => "spawn_specialist",
                  "tool_use_id" => "toolu_sibling"},
        timestamp: 4, token_count: 10
      )

      child.events.create!(event_type: "user_message", payload: {"content" => "my task"}, timestamp: 5, token_count: 10)

      events = child.viewport_events
      tool_names = events.select { |e| e.event_type.in?(%w[tool_call tool_response]) }
        .map { |e| e.payload["tool_name"] }

      expect(tool_names).not_to include("spawn_specialist")
      expect(events.map { |e| e.payload["content"] }).to include("parent msg 1", "parent reply 1", "my task")
    end

    it "excludes own spawn events from parent context" do
      # The sub-agent's own spawn pair is also noise — the task is already its first user_message
      parent.events.create!(
        event_type: "tool_call",
        payload: {"content" => "Calling spawn_subagent", "tool_name" => "spawn_subagent",
                  "tool_input" => {"task" => "research"}, "tool_use_id" => "toolu_self"},
        timestamp: 3, token_count: 10
      )
      parent.events.create!(
        event_type: "tool_response",
        payload: {"content" => "Sub-agent spawned", "tool_name" => "spawn_subagent",
                  "tool_use_id" => "toolu_self"},
        timestamp: 4, token_count: 10
      )

      child.events.create!(event_type: "user_message", payload: {"content" => "my task"}, timestamp: 5, token_count: 10)

      events = child.viewport_events
      tool_names = events.select { |e| e.event_type.in?(%w[tool_call tool_response]) }
        .map { |e| e.payload["tool_name"] }

      expect(tool_names).not_to include("spawn_subagent")
    end

    it "preserves non-spawn tool events in parent context" do
      parent.events.create!(
        event_type: "tool_call",
        payload: {"content" => "Calling bash", "tool_name" => "bash",
                  "tool_input" => {"command" => "ls"}, "tool_use_id" => "toolu_bash"},
        timestamp: 3, token_count: 10
      )
      parent.events.create!(
        event_type: "tool_response",
        payload: {"content" => "file1.rb", "tool_name" => "bash",
                  "tool_use_id" => "toolu_bash"},
        timestamp: 4, token_count: 10
      )

      child.events.create!(event_type: "user_message", payload: {"content" => "my task"}, timestamp: 5, token_count: 10)

      events = child.viewport_events
      tool_names = events.select { |e| e.event_type.in?(%w[tool_call tool_response]) }
        .map { |e| e.payload["tool_name"] }

      expect(tool_names).to eq(%w[bash bash])
    end

    it "trims trailing tool_call events from parent viewport" do
      parent.events.create!(
        event_type: "tool_call",
        payload: {"content" => "Calling spawn_subagent", "tool_name" => "spawn_subagent",
                  "tool_input" => {"task" => "research"}, "tool_use_id" => "toolu_orphan"},
        timestamp: 3, token_count: 10
      )

      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 4, token_count: 10)

      events = child.viewport_events
      types = events.map(&:event_type)

      # The orphaned tool_call at the end of parent events should be trimmed
      expect(types).not_to include("tool_call")
    end
  end

  describe "#recalculate_viewport!" do
    let(:session) { Session.create! }

    it "returns empty array when viewport has not changed" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
      session.snapshot_viewport!([event.id])

      expect(session.recalculate_viewport!).to eq([])
    end

    it "returns evicted event IDs when viewport shrinks" do
      old = session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 100_000)
      new_event = session.events.create!(event_type: "agent_message", payload: {"content" => "new"}, timestamp: 2, token_count: 100_000)
      session.update_column(:viewport_event_ids, [old.id, new_event.id])

      # Add a large event that pushes 'old' out of the viewport
      session.events.create!(event_type: "user_message", payload: {"content" => "big"}, timestamp: 3, token_count: 100_000)

      evicted = session.recalculate_viewport!
      expect(evicted).to include(old.id)
    end

    it "updates the stored viewport snapshot" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
      session.recalculate_viewport!

      expect(session.reload.viewport_event_ids).to eq([event.id])
    end

    it "does not write to the database when viewport is unchanged" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
      session.snapshot_viewport!([event.id])

      expect(session).not_to receive(:update_column)
      session.recalculate_viewport!
    end
  end

  describe "#snapshot_viewport!" do
    let(:session) { Session.create! }

    it "stores the given event IDs" do
      session.snapshot_viewport!([1, 2, 3])
      expect(session.reload.viewport_event_ids).to eq([1, 2, 3])
    end

    it "overwrites previous snapshot" do
      session.snapshot_viewport!([1, 2])
      session.snapshot_viewport!([3, 4, 5])
      expect(session.reload.viewport_event_ids).to eq([3, 4, 5])
    end
  end

  describe "#assemble_recall_messages" do
    let(:session) { Session.create! }

    def create_event(sess, type:, content:)
      sess.events.create!(
        event_type: type,
        payload: {"content" => content},
        timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      )
    end

    it "returns empty when no recalled event IDs" do
      expect(session.send(:assemble_recall_messages, budget: 1000)).to eq([])
    end

    it "returns recall messages for stored event IDs" do
      other_session = Session.create!(name: "Past Work")
      event = create_event(other_session, type: "user_message", content: "Important finding about auth")
      session.update_column(:recalled_event_ids, [event.id])

      messages = session.send(:assemble_recall_messages, budget: 1000)

      expect(messages.size).to eq(1)
      expect(messages.first[:role]).to eq("user")
      expect(messages.first[:content]).to include("[associative recall]")
      expect(messages.first[:content]).to include("Important finding about auth")
      expect(messages.first[:content]).to include("Past Work")
    end

    it "respects budget and stops when exceeded" do
      other_session = Session.create!
      e1 = create_event(other_session, type: "user_message", content: "A" * 500)
      e2 = create_event(other_session, type: "user_message", content: "B" * 500)
      session.update_column(:recalled_event_ids, [e1.id, e2.id])

      messages = session.send(:assemble_recall_messages, budget: 50)

      # Budget should allow at least one snippet but not both
      expect(messages.first[:content]).to include("A")
    end

    it "skips events that no longer exist" do
      event = create_event(session, type: "user_message", content: "Still here")
      session.update_column(:recalled_event_ids, [999999, event.id])

      messages = session.send(:assemble_recall_messages, budget: 1000)

      expect(messages.first[:content]).to include("Still here")
      expect(messages.first[:content]).not_to include("999999")
    end

    it "falls back to session ID when name is nil" do
      unnamed_session = Session.create!(name: nil)
      event = create_event(unnamed_session, type: "user_message", content: "test")
      session.update_column(:recalled_event_ids, [event.id])

      messages = session.send(:assemble_recall_messages, budget: 1000)

      expect(messages.first[:content]).to include("session ##{unnamed_session.id}")
    end
  end

  describe "#extract_event_content (private)" do
    let(:session) { Session.create! }

    it "extracts content from user messages" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello world"},
        timestamp: 1
      )

      expect(session.send(:extract_event_content, event)).to eq("Hello world")
    end

    it "extracts thoughts from think tool calls" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "think", "tool_input" => {"thoughts" => "Deep thought"}, "tool_use_id" => "t1"},
        timestamp: 1
      )

      expect(session.send(:extract_event_content, event)).to eq("Deep thought")
    end

    it "returns tool name summary for non-think tool calls" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"tool_name" => "bash", "tool_input" => {"cmd" => "ls"}, "tool_use_id" => "t1"},
        timestamp: 1
      )

      expect(session.send(:extract_event_content, event)).to eq("bash(…)")
    end
  end

  describe "#estimate_tokens (private)" do
    let(:session) { Session.create! }

    it "delegates to Event#estimate_tokens" do
      event = session.events.create!(
        event_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1
      )

      expect(session.send(:estimate_tokens, event)).to eq(event.estimate_tokens)
    end

    it "uses heuristic for tool events via Event#estimate_tokens" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        timestamp: 1
      )

      expect(session.send(:estimate_tokens, event)).to eq(event.estimate_tokens)
    end
  end
end
