# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Message} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
#
# Sessions form a hierarchy: a main session can spawn child sessions
# (sub-agents) that inherit the parent's viewport context at fork time.
class Session < ApplicationRecord
  class MissingSoulError < StandardError; end

  VIEW_MODES = %w[basic verbose debug].freeze

  attribute :view_mode, :string, default: -> { Anima::Settings.default_view_mode }

  serialize :granted_tools, coder: JSON

  has_many :messages, -> { order(:id) }, dependent: :destroy
  has_many :pending_messages, dependent: :destroy
  has_many :goals, dependent: :destroy
  has_many :snapshots, dependent: :destroy
  has_many :pinned_messages, through: :messages

  belongs_to :parent_session, class_name: "Session", optional: true
  has_many :child_sessions, class_name: "Session", foreign_key: :parent_session_id, dependent: :destroy

  validates :view_mode, inclusion: {in: VIEW_MODES}
  validates :name, length: {maximum: 255}, allow_nil: true

  after_update_commit :broadcast_name_update, if: :saved_change_to_name?
  after_update_commit :broadcast_active_skills_update, if: :saved_change_to_active_skills?
  after_update_commit :broadcast_active_workflow_update, if: :saved_change_to_active_workflow?

  scope :recent, ->(limit = 10) { order(updated_at: :desc).limit(limit) }
  scope :root_sessions, -> { where(parent_session_id: nil) }
  scope :processing_children_of, ->(parent_id) { where(parent_session_id: parent_id, processing: true) }

  # Cycles to the next view mode: basic → verbose → debug → basic.
  #
  # @return [String] the next view mode in the cycle
  def next_view_mode
    current_index = VIEW_MODES.index(view_mode) || 0
    VIEW_MODES[(current_index + 1) % VIEW_MODES.size]
  end

  # @return [Boolean] true if this session is a sub-agent (has a parent)
  def sub_agent?
    parent_session_id.present?
  end

  # Checks whether the Mneme terminal message has left the viewport and
  # enqueues {MnemeJob} when it has. On the first message of a new session,
  # initializes the boundary pointer.
  #
  # The terminal message is always a conversation message (user/agent message
  # or think tool_call), never a bare tool_call/tool_response.
  #
  # @return [void]
  def schedule_mneme!
    return if sub_agent?

    # Initialize boundary on first conversation message
    if mneme_boundary_message_id.nil?
      first_conversation = messages
        .where(message_type: Message::CONVERSATION_TYPES)
        .order(:id).first
      first_conversation ||= messages
        .where(message_type: "tool_call")
        .detect { |msg| msg.payload["tool_name"] == Message::THINK_TOOL }

      if first_conversation
        update_column(:mneme_boundary_message_id, first_conversation.id)
      end
      return
    end

    # Check if boundary message has left the viewport
    return if viewport_message_ids.include?(mneme_boundary_message_id)

    MnemeJob.perform_later(id)
  end

  # Enqueues the analytical brain to perform background maintenance on
  # this session. Currently handles session naming; future phases add
  # skill activation, goal tracking, and memory.
  #
  # Runs after the first exchange and periodically as the conversation
  # evolves, so the name stays relevant to the current topic.
  #
  # @return [void]
  def schedule_analytical_brain!
    return if sub_agent?

    count = messages.llm_messages.count
    return if count < 2
    # Already named — only regenerate at interval boundaries (30, 60, 90, …)
    return if name.present? && (count % Anima::Settings.name_generation_interval != 0)

    AnalyticalBrainJob.perform_later(id)
  end

  # Returns the messages currently visible in the LLM context window.
  # Walks messages newest-first and includes them until the token budget
  # is exhausted. Messages are full-size or excluded entirely.
  #
  # Pending messages live in a separate table ({PendingMessage}) and never
  # appear in this viewport — they are promoted to real messages before
  # the agent processes them.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Message>] chronologically ordered
  def viewport_messages(token_budget: Anima::Settings.token_budget)
    select_messages(own_message_scope, budget: token_budget)
  end

  # Recalculates the viewport and returns IDs of messages evicted since the
  # last snapshot. Updates the stored viewport_message_ids atomically.
  # Piggybacks on message broadcasts to notify clients which messages left
  # the LLM's context window.
  #
  # @return [Array<Integer>] IDs of messages no longer in the viewport
  def recalculate_viewport!
    new_ids = viewport_messages.map(&:id)
    old_ids = viewport_message_ids

    evicted = old_ids - new_ids
    update_column(:viewport_message_ids, new_ids) if old_ids != new_ids
    evicted
  end

  # Overwrites the viewport snapshot without computing evictions.
  # Used when transmitting or broadcasting a full viewport refresh,
  # where eviction notifications are unnecessary (clients clear their
  # store first).
  #
  # @param ids [Array<Integer>] message IDs now in the viewport
  # @return [void]
  def snapshot_viewport!(ids)
    update_column(:viewport_message_ids, ids)
  end

  # Returns the system prompt for this session.
  # Sub-agent sessions use their stored prompt plus active skills and
  # the pinned task. Main sessions assemble a full system prompt from
  # soul, environment, skills/workflow, and goals.
  #
  # @param environment_context [String, nil] pre-assembled environment block
  #   from {EnvironmentProbe}; injected between soul and expertise sections
  # @return [String, nil] the system prompt text, or nil when nothing to inject
  def system_prompt(environment_context: nil)
    if sub_agent?
      [prompt, assemble_expertise_section, assemble_task_section].compact.join("\n\n")
    else
      assemble_system_prompt(environment_context: environment_context)
    end
  end

  # Activates a skill on this session. Validates the skill exists in the
  # registry, adds it to active_skills, and persists.
  #
  # @param skill_name [String] name of the skill to activate
  # @return [Skills::Definition] the activated skill
  # @raise [Skills::InvalidDefinitionError] if skill not found in registry
  # @raise [ActiveRecord::RecordInvalid] if save fails
  def activate_skill(skill_name)
    definition = Skills::Registry.instance.find(skill_name)
    raise Skills::InvalidDefinitionError, "Unknown skill: #{skill_name}" unless definition

    return definition if active_skills.include?(skill_name)

    self.active_skills = active_skills + [skill_name]
    save!
    definition
  end

  # Deactivates a skill on this session. Removes it from active_skills and persists.
  #
  # @param skill_name [String] name of the skill to deactivate
  # @return [void]
  def deactivate_skill(skill_name)
    return unless active_skills.include?(skill_name)

    self.active_skills = active_skills - [skill_name]
    save!
  end

  # Activates a workflow on this session. Validates the workflow exists in the
  # registry, sets it as the active workflow, and persists. Only one workflow
  # can be active at a time — activating a new one replaces the previous.
  #
  # @param workflow_name [String] name of the workflow to activate
  # @return [Workflows::Definition] the activated workflow
  # @raise [Workflows::InvalidDefinitionError] if workflow not found in registry
  # @raise [ActiveRecord::RecordInvalid] if save fails
  def activate_workflow(workflow_name)
    definition = Workflows::Registry.instance.find(workflow_name)
    raise Workflows::InvalidDefinitionError, "Unknown workflow: #{workflow_name}" unless definition

    return definition if active_workflow == workflow_name

    self.active_workflow = workflow_name
    save!
    definition
  end

  # Deactivates the current workflow on this session.
  #
  # @return [void]
  def deactivate_workflow
    return unless active_workflow.present?

    self.active_workflow = nil
    save!
  end

  # Assembles the system prompt: version preamble, soul, environment context,
  # skills/workflow, then goals.
  # The soul is always present — "who am I" before "what can I do."
  #
  # @param environment_context [String, nil] pre-assembled environment block
  # @return [String] composed system prompt
  def assemble_system_prompt(environment_context: nil)
    [assemble_version_preamble, assemble_soul_section, assemble_snapshots_section,
      environment_context, assemble_expertise_section, assemble_goals_section].compact.join("\n\n")
  end

  # Serializes non-evicted goals as a lightweight summary for ActionCable
  # broadcasts and TUI display. Returns a nested structure: root goals
  # with their sub-goals inlined. Evicted goals and their sub-goals are
  # excluded.
  #
  # @return [Array<Hash>] each with :id, :description, :status, and :sub_goals
  def goals_summary
    goals.root.not_evicted.includes(:sub_goals).order(:created_at).map(&:as_summary)
  end

  # Builds the message array expected by the Anthropic Messages API.
  # Viewport layout (top to bottom):
  #   [pinned messages] [sliding window messages]
  #
  # Snapshots live in the system prompt (stable between Mneme runs).
  # Recalled memories are phantom tool_call/tool_response pairs injected
  # by {Mneme::PassiveRecall} — they ride the conveyor belt as regular
  # messages and are included in the sliding window automatically.
  # Pinned messages are critical context attached to active Goals — they
  # survive eviction intact until their Goals complete.
  #
  # The sliding window is post-processed by {#ensure_atomic_tool_pairs}
  # which removes orphaned tool messages whose partner was cut off by the
  # token budget.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Hash>] Anthropic Messages API format
  def messages_for_llm(token_budget: Anima::Settings.token_budget)
    heal_orphaned_tool_calls!

    sliding_budget = token_budget

    pinned_budget = (token_budget * Anima::Settings.mneme_pinned_budget_fraction).to_i
    sliding_budget -= pinned_budget

    window = viewport_messages(token_budget: sliding_budget)
    first_message_id = window.first&.id

    pinned_messages = assemble_pinned_section_messages(first_message_id, budget: pinned_budget)

    pinned_messages + assemble_messages(ensure_atomic_tool_pairs(window))
  end

  # Detects orphaned tool_call messages (those without a matching tool_response
  # and whose timeout has expired) and creates synthetic error responses.
  # An orphaned tool_call permanently breaks the session because the
  # Anthropic API rejects conversations where a tool_use block has no
  # matching tool_result.
  #
  # Respects the per-call timeout stored in the tool_call message payload —
  # a tool_call is only healed after its deadline has passed. This avoids
  # prematurely healing long-running tools that the agent intentionally
  # gave an extended timeout.
  #
  # @return [Integer] number of synthetic responses created
  def heal_orphaned_tool_calls!
    current_ns = now_ns
    responded_ids = messages.where(message_type: "tool_response").select(:tool_use_id)
    unresponded = messages.where(message_type: "tool_call")
      .where.not(tool_use_id: responded_ids)

    healed = 0
    unresponded.find_each do |orphan|
      timeout = orphan.payload["timeout"] || Anima::Settings.tool_timeout
      deadline_ns = orphan.timestamp + (timeout * 1_000_000_000)
      next if current_ns < deadline_ns

      messages.create!(
        message_type: "tool_response",
        payload: {
          "type" => "tool_response",
          "content" => "Tool execution timed out after #{timeout} seconds — no result was returned.",
          "tool_name" => orphan.payload["tool_name"],
          "tool_use_id" => orphan.tool_use_id,
          "success" => false
        },
        tool_use_id: orphan.tool_use_id,
        timestamp: current_ns
      )
      healed += 1
    end
    healed
  end

  # Delivers a user message respecting the session's processing state.
  #
  # When idle, persists the message directly and enqueues {AgentRequestJob}
  # to process it. When mid-turn ({#processing?}), stages the message as
  # a {PendingMessage} in a separate table — it gets no message ID until
  # promoted, so it can never interleave with tool_call/tool_response pairs.
  #
  # @param content [String] message text (raw, without attribution)
  # @param source_type [String] origin type: "user" (default) or "subagent"
  # @param source_name [String, nil] sub-agent nickname (required when source_type is "subagent")
  # @param bounce_back [Boolean] when true, passes +message_id+ to the job
  #   so failed LLM delivery triggers a {Events::BounceBack} (used by
  #   {SessionChannel#speak} for immediate-display messages)
  # @return [void]
  def enqueue_user_message(content, source_type: "user", source_name: nil, bounce_back: false)
    if processing?
      pending_messages.create!(content: content, source_type: source_type, source_name: source_name)
    else
      display = if source_type == "subagent"
        format(Tools::ResponseTruncator::ATTRIBUTION_FORMAT, source_name, content)
      else
        content
      end
      msg = create_user_message(display)
      job_args = bounce_back ? {message_id: msg.id} : {}
      AgentRequestJob.perform_later(id, **job_args)
    end
  end

  # Promotes a recall pending message into a phantom tool_call/tool_response pair.
  # These persist as real Message records and ride the conveyor belt.
  #
  # @param pm [PendingMessage] recall pending message (source_name = recalled message ID)
  # @return [void]
  def promote_recall_message!(pm)
    uid = "recall_#{pm.source_name}"
    now = now_ns

    messages.create!(
      message_type: "tool_call",
      tool_use_id: uid,
      payload: {"tool_name" => PendingMessage::RECALL_TOOL_NAME, "tool_use_id" => uid,
                "tool_input" => {"message_id" => pm.source_name.to_i},
                "content" => "Recalling message #{pm.source_name}"},
      timestamp: now,
      token_count: Mneme::PassiveRecall::TOOL_PAIR_OVERHEAD_TOKENS
    )

    messages.create!(
      message_type: "tool_response",
      tool_use_id: uid,
      payload: {"tool_name" => PendingMessage::RECALL_TOOL_NAME, "tool_use_id" => uid,
                "content" => pm.content, "success" => true},
      timestamp: now,
      token_count: Message.estimate_token_count(pm.content.bytesize)
    )
  end

  # Persists a user message directly, bypassing the pending queue.
  #
  # Used by {#enqueue_user_message} (idle path), {AgentLoop#run},
  # and sub-agent spawn tools ({Tools::SpawnSubagent}, {Tools::SpawnSpecialist})
  # because the global {Events::Subscribers::Persister} skips non-pending user
  # messages — these callers own the persistence lifecycle.
  #
  # @param content [String] user message text
  # @return [Message] the persisted message record
  def create_user_message(content)
    now = now_ns
    messages.create!(
      message_type: "user_message",
      payload: {type: "user_message", content: content, session_id: id, timestamp: now},
      timestamp: now
    )
  end

  # Promotes all pending messages into the conversation history.
  # Each {PendingMessage} is atomically deleted and replaced with a real
  # {Message} — the new message gets the next auto-increment ID,
  # naturally placing it after any tool_call/tool_response pairs that
  # were persisted while the message was waiting.
  #
  # Returns a hash with two keys:
  # - +:texts+ — plain content strings for user messages (injected as text blocks
  #   within the current tool_results turn)
  # - +:pairs+ — synthetic tool_use/tool_result message hashes for sub-agent
  #   messages (appended as new conversation turns)
  #
  # @return [Hash{Symbol => Array}] promoted messages split by injection strategy
  def promote_pending_messages!
    texts = []
    pairs = []
    pending_messages.find_each do |pm|
      transaction do
        if pm.recall?
          promote_recall_message!(pm)
        else
          create_user_message(pm.display_content)
        end
        pm.destroy!
      end
      if pm.subagent? || pm.recall?
        pairs.concat(pm.to_llm_messages)
      else
        texts << pm.content
      end
    end
    {texts: texts, pairs: pairs}
  end

  # Broadcasts child session list to all clients subscribed to the parent
  # session. Called when a child session is created or its processing state
  # changes so the HUD sub-agents section updates in real time.
  #
  # Queries children via FK directly (avoids loading the parent record) and
  # selects only the columns needed for the HUD payload.
  #
  # @return [void]
  def broadcast_children_update_to_parent
    return unless parent_session_id

    children = Session.where(parent_session_id: parent_session_id)
      .order(:created_at)
      .select(:id, :name, :processing)
    ActionCable.server.broadcast("session_#{parent_session_id}", {
      "action" => "children_updated",
      "session_id" => parent_session_id,
      "children" => children.map { |child|
        state = child.processing? ? "llm_generating" : "idle"
        {"id" => child.id, "name" => child.name, "processing" => child.processing?, "session_state" => state}
      }
    })
  end

  # Broadcasts the session's current processing state to all subscribed
  # clients. Stateless — no storage, pure broadcast. The TUI uses this to
  # drive the braille spinner animation and sub-agent HUD icons.
  #
  # Payload broadcast to +session_{id}+:
  #   {"action" => "session_state", "state" => state, "session_id" => id}
  #   # plus "tool" key when state is "tool_executing"
  #
  # For sub-agents, also broadcasts +child_state+ to the parent stream:
  #   {"action" => "child_state", "state" => state, "session_id" => id, "child_id" => id}
  #
  # @param state [String] one of "idle", "llm_generating", "tool_executing", "interrupting"
  # @param tool [String, nil] tool name when state is "tool_executing"
  # @return [void]
  def broadcast_session_state(state, tool: nil)
    payload = {"action" => "session_state", "state" => state, "session_id" => id}
    payload["tool"] = tool if tool
    ActionCable.server.broadcast("session_#{id}", payload)

    # Notify the parent's stream so the HUD updates child state icons
    # without requiring a full children_updated query.
    return unless parent_session_id

    parent_payload = payload.merge("action" => "child_state", "child_id" => id)
    ActionCable.server.broadcast("session_#{parent_session_id}", parent_payload)
  end

  # Broadcasts the full LLM debug context to debug-mode TUI clients.
  # Called on every LLM request so the TUI shows exactly what the LLM
  # receives — system prompt and tool schemas. No-op outside debug mode.
  #
  # @param system [String, nil] the final system prompt sent to the LLM
  # @param tools [Array<Hash>, nil] tool schemas sent to the LLM
  # @return [void]
  def broadcast_debug_context(system:, tools: nil)
    return unless view_mode == "debug" && system

    ActionCable.server.broadcast("session_#{id}", self.class.system_prompt_payload(system, tools: tools))
  end

  # Returns the deterministic tool schemas for this session's type and
  # granted_tools configuration. Standard and spawn tools are static
  # class-level definitions — no ShellSession or registry needed.
  # MCP tools are excluded (they require live server queries and appear
  # after the first LLM request via {#broadcast_debug_context}).
  #
  # @return [Array<Hash>] tool schema hashes matching Anthropic tools API format
  def tool_schemas
    tools = if granted_tools
      granted = granted_tools.filter_map { |name| AgentLoop::STANDARD_TOOLS_BY_NAME[name] }
      (AgentLoop::ALWAYS_GRANTED_TOOLS + granted).uniq
    else
      AgentLoop::STANDARD_TOOLS.dup
    end

    unless sub_agent?
      tools.push(Tools::SpawnSubagent, Tools::SpawnSpecialist, Tools::OpenIssue)
    end

    if sub_agent?
      tools.push(Tools::MarkGoalCompleted)
    end

    tools.map(&:schema)
  end

  # Builds the system prompt payload for debug mode transmission.
  # Token estimate covers both the system prompt and tool schemas
  # since both consume the LLM's context window.
  # Tools are sent as raw schemas; the TUI formats them as TOON for display.
  #
  # @param prompt [String] system prompt text
  # @param tools [Array<Hash>, nil] tool schemas
  # @return [Hash] payload with type, rendered debug content, and token estimate
  def self.system_prompt_payload(prompt, tools: nil)
    total_bytes = prompt.bytesize
    total_bytes += tools.to_json.bytesize if tools&.any?
    tokens = Message.estimate_token_count(total_bytes)

    debug = {role: :system_prompt, content: prompt, tokens: tokens, estimated: true}
    debug[:tools] = tools if tools&.any?

    {
      "id" => Message::SYSTEM_PROMPT_ID,
      "type" => "system_prompt",
      "rendered" => {"debug" => debug}
    }
  end

  private

  # One-line version preamble so the agent knows its own version.
  # Useful for commits, handoffs, and debugging.
  #
  # @return [String] e.g. "You are running on Anima v1.1.3"
  def assemble_version_preamble
    "You are running on Anima v#{Anima::VERSION}"
  end

  # Reads the soul file — the agent's self-authored identity.
  # Loaded as the first section of every system prompt, before skills,
  # workflows, and goals.
  #
  # @return [String] soul content
  # @raise [MissingSoulError] when the soul file does not exist
  def assemble_soul_section
    path = Anima::Settings.soul_path
    unless File.exist?(path)
      raise MissingSoulError, "Soul file not found: #{path}. Run `anima install` to create it."
    end

    File.read(path).strip
  end

  # Assembles the expertise section of the system prompt from active skills
  # and the active workflow. Both are injected into the same "Your Expertise"
  # section — the main agent treats them identically as domain knowledge.
  #
  # @return [String, nil] expertise section, or nil when nothing is active
  def assemble_expertise_section
    sections = active_skills.filter_map do |skill_name|
      definition = Skills::Registry.instance.find(skill_name)
      format_expertise_section(definition, skill_name)
    end

    if active_workflow.present?
      definition = Workflows::Registry.instance.find(active_workflow)
      sections << format_expertise_section(definition, active_workflow) if definition
    end

    return if sections.empty?

    "## Your Expertise\n\nYou know this deeply. Now's your chance to put it to work.\n\n#{sections.join("\n\n")}"
  end

  # Evicts completed goals that have aged past the configured threshold
  # of meaningful messages (user + agent turns). Pure arithmetic — no LLM
  # involvement. Called before prompt assembly so evicted goals are
  # excluded from the very next context window.
  #
  # @return [void]
  def evict_stale_goals!
    threshold = Anima::Settings.completed_decay_messages
    goals.evictable.each do |goal|
      messages_since = messages.llm_messages.where("created_at > ?", goal.completed_at).count
      goal.update!(evicted_at: Time.current) if messages_since >= threshold
    end
  end

  # Assembles the goals section of the system prompt.
  # Automatically evicts stale completed goals before filtering.
  # Active root goals render as `###` headings with sub-goal checkboxes.
  # Completed root goals collapse to a single strikethrough line.
  # Evicted goals are excluded entirely to free context budget.
  #
  # @return [String, nil] goals section, or nil when no goals exist
  def assemble_goals_section
    evict_stale_goals!

    root_goals = goals.root.not_evicted.includes(:sub_goals).order(:created_at)
    return if root_goals.empty?

    entries = root_goals.map { |goal| render_goal_markdown(goal) }
    "Current Goals\n=============\n\n#{entries.join("\n\n")}"
  end

  # Assembles the task section for sub-agent system prompts.
  # Sub-agents have a single pinned goal — their entire raison d'etre.
  # Rendered as a persistent task block so the LLM always knows what it
  # was spawned to do, regardless of conversation length.
  #
  # @return [String, nil] task section, or nil when no active goal exists
  def assemble_task_section
    goal = goals.active.root.first
    return unless goal

    <<~SECTION.strip
      Your Task
      =========

      #{goal.description}

      Complete this task and call mark_goal_completed when done.
    SECTION
  end

  # Renders a single root goal with its sub-goals as Markdown.
  # Active goals show full hierarchy; completed goals collapse to one line.
  #
  # @param goal [Goal] a root goal
  # @return [String] Markdown fragment
  def render_goal_markdown(goal)
    description = goal.description
    return "### ~~#{description}~~ ✓" if goal.completed?

    lines = ["### #{description}"]
    goal.sub_goals.each do |sub|
      checkbox = sub.completed? ? "[x]" : "[ ]"
      lines << "- #{checkbox} #{sub.description}"
    end
    lines.join("\n")
  end

  # Formats a definition (skill or workflow) as a Markdown section for the
  # expertise prompt. Extracts the first Markdown heading from content for
  # the section title; falls back to the definition name when content has
  # no heading.
  #
  # @param definition [Skills::Definition, Workflows::Definition, nil] the definition to format
  # @param fallback_name [String] name to use if content has no heading
  # @return [String, nil] formatted section, or nil if definition is nil
  def format_expertise_section(definition, fallback_name)
    return unless definition

    content = definition.content
    heading = content.lines.first&.sub(/^#+ /, "")&.strip || fallback_name
    "### #{heading}\n\n#{content}"
  end

  # Broadcasts a name change to all clients subscribed to this session.
  # Triggered by after_update_commit so clients see name updates in real time.
  #
  # @return [void]
  def broadcast_name_update
    ActionCable.server.broadcast("session_#{id}", {
      "action" => "session_name_updated",
      "session_id" => id,
      "name" => name
    })
  end

  # Broadcasts active skill changes to all clients subscribed to this session.
  # Triggered by after_update_commit so the TUI info panel updates reactively.
  #
  # @return [void]
  def broadcast_active_skills_update
    ActionCable.server.broadcast("session_#{id}", {
      "action" => "active_skills_updated",
      "session_id" => id,
      "active_skills" => active_skills
    })
  end

  # Broadcasts active workflow change to all clients subscribed to this session.
  # Triggered by after_update_commit so the TUI info panel updates reactively.
  #
  # @return [void]
  def broadcast_active_workflow_update
    ActionCable.server.broadcast("session_#{id}", {
      "action" => "active_workflow_updated",
      "session_id" => id,
      "active_workflow" => active_workflow
    })
  end

  # Scopes own messages for viewport assembly.
  # Starts from the Mneme boundary (inclusive) — older messages have been
  # compressed into snapshots and no longer participate in the viewport.
  # @return [ActiveRecord::Relation]
  def own_message_scope
    scope = messages.context_messages
    scope = scope.where("messages.id >= ?", mneme_boundary_message_id) if mneme_boundary_message_id
    scope
  end

  # Walks messages newest-first, selecting until the token budget is exhausted.
  # Always includes at least the newest message even if it exceeds budget.
  #
  # @param scope [ActiveRecord::Relation] message scope to select from
  # @param budget [Integer] maximum tokens to include
  # @return [Array<Message>] chronologically ordered
  def select_messages(scope, budget:)
    selected = []
    remaining = budget

    scope.reorder(id: :desc).each do |msg|
      cost = message_token_cost(msg)
      break if cost > remaining && selected.any?

      selected << msg
      remaining -= cost
    end

    selected.reverse
  end

  # @return [Integer] token cost, using cached count or heuristic estimate
  def message_token_cost(msg)
    (msg.token_count > 0) ? msg.token_count : estimate_tokens(msg)
  end

  # Ensures every tool_call in the message list has a matching tool_response
  # (and vice versa) by removing unpaired messages. The Anthropic API requires
  # every tool_use block to have a tool_result — a missing partner causes
  # a permanent API error. Token budget cutoffs can split pairs when the
  # boundary falls between a tool_call and its tool_response.
  #
  # @param message_list [Array<Message>] chronologically ordered messages
  # @return [Array<Message>] messages with unpaired tool messages removed
  def ensure_atomic_tool_pairs(message_list)
    tool_msgs = message_list.select { |m| m.tool_use_id.present? }
    return message_list if tool_msgs.empty?

    paired = tool_msgs.group_by(&:tool_use_id)
    complete_ids = paired.each_with_object(Set.new) do |(uid, msgs), set|
      has_call = msgs.any? { |m| m.message_type == "tool_call" }
      has_response = msgs.any? { |m| m.message_type == "tool_response" }
      set << uid if has_call && has_response
    end

    message_list.reject { |m| m.tool_use_id.present? && !complete_ids.include?(m.tool_use_id) }
  end

  # Assembles L1/L2 snapshots as a system prompt section.
  # Snapshots are visible when their source messages precede the Mneme boundary
  # (compressed in a previous run). Between Mneme runs this section is frozen,
  # making it cache-friendly.
  #
  # @return [String, nil] formatted snapshot text for the system prompt, or nil
  def assemble_snapshots_section
    reference_id = mneme_boundary_message_id || viewport_message_ids.first
    return unless reference_id

    l2_budget = (Anima::Settings.token_budget * Anima::Settings.mneme_l2_budget_fraction).to_i
    l1_budget = (Anima::Settings.token_budget * Anima::Settings.mneme_l1_budget_fraction).to_i

    l2 = select_snapshots_within_budget(
      snapshots.for_level(2).source_messages_evicted(reference_id).chronological,
      budget: l2_budget
    )
    l1 = select_snapshots_within_budget(
      snapshots.for_level(1).not_covered_by_l2.source_messages_evicted(reference_id).chronological,
      budget: l1_budget
    )

    sections = []
    sections << format_snapshots_text(l2, label: "Long-term Memory") if l2.any?
    sections << format_snapshots_text(l1, label: "Recent Memory") if l1.any?
    sections.join("\n\n").presence
  end

  # Walks snapshots chronologically, selecting until the token budget is exhausted.
  # Always includes at least one snapshot even if it exceeds the budget, so the
  # agent never loses all memory context.
  #
  # @param scope [ActiveRecord::Relation] snapshot scope to select from
  # @param budget [Integer] maximum tokens to include
  # @return [Array<Snapshot>]
  def select_snapshots_within_budget(scope, budget:)
    selected = []
    remaining = budget

    scope.each do |snapshot|
      cost = snapshot.token_cost
      break if cost > remaining && selected.any?

      selected << snapshot
      remaining -= cost
    end

    selected
  end

  # Formats a list of snapshots as a labeled section for the system prompt.
  #
  # @param snapshots_list [Array<Snapshot>]
  # @param label [String] section heading
  # @return [String]
  def format_snapshots_text(snapshots_list, label:)
    texts = snapshots_list.map(&:text)
    "## #{label}\n\n#{texts.join("\n\n")}"
  end

  # Assembles pinned messages as a Goals section message for the viewport.
  # Only includes pinned messages whose source message has evicted from the
  # sliding window (same rule as snapshots — no duplication with live messages).
  #
  # Deduplication: the first Goal referencing a message shows its truncated
  # display_text; subsequent Goals show a bare `message N` ID to save tokens.
  #
  # @param first_message_id [Integer, nil] first message ID in the sliding window
  # @param budget [Integer] token budget for pinned messages
  # @return [Array<Hash>] Anthropic Messages API format (0 or 1 messages)
  def assemble_pinned_section_messages(first_message_id, budget:)
    return [] unless first_message_id

    pins = pinned_messages
      .includes(:message, :goals)
      .where("pinned_messages.message_id < ?", first_message_id)
      .order("pinned_messages.message_id")

    return [] if pins.empty?

    selected = select_pins_within_budget(pins, budget)
    return [] if selected.empty?

    text = render_pinned_messages_section(selected)
    [{role: "user", content: "[pinned messages]\n#{text}"}]
  end

  # Walks pinned messages chronologically, selecting until the token budget
  # is exhausted. Always includes at least one pin.
  #
  # @param pins [Array<PinnedMessage>]
  # @param budget [Integer]
  # @return [Array<PinnedMessage>]
  def select_pins_within_budget(pins, budget)
    selected = []
    remaining = budget

    pins.each do |pin|
      cost = pin.token_cost
      break if cost > remaining && selected.any?

      selected << pin
      remaining -= cost
    end

    selected
  end

  # Renders the pinned messages section grouped by Goal.
  # First Goal referencing a pin shows truncated text; subsequent Goals
  # show bare `message N` ID to avoid token-expensive repetition.
  #
  # @param pins [Array<PinnedMessage>] selected pins with preloaded goals
  # @return [String] formatted section text
  def render_pinned_messages_section(pins)
    goal_pins = group_pins_by_active_goal(pins)

    shown_messages = Set.new
    goal_pins.map { |goal, pin_list|
      render_goal_pins(goal, pin_list, shown_messages)
    }.join("\n\n")
  end

  # Groups pins by their active Goals so the viewport renders
  # one headed section per Goal.
  #
  # @param pins [Array<PinnedMessage>] pins with preloaded goals
  # @return [Hash{Goal => Array<PinnedMessage>}]
  def group_pins_by_active_goal(pins)
    pairs = pins.flat_map { |pin| active_goal_pin_pairs(pin) }
    pairs.group_by(&:first).transform_values { |group| group.map(&:last) }
  end

  # Expands a single pin into [goal, pin] pairs for each active Goal
  # referencing it. Uses in-memory filter on preloaded goals.
  #
  # @param pin [PinnedMessage]
  # @return [Array<Array(Goal, PinnedMessage)>]
  def active_goal_pin_pairs(pin)
    pin.goals.select(&:active?).map { |goal| [goal, pin] }
  end

  # Renders one Goal's pinned messages as a headed list.
  #
  # @param goal [Goal]
  # @param pin_list [Array<PinnedMessage>]
  # @param shown_messages [Set<Integer>] tracks already-rendered message IDs for dedup
  # @return [String]
  def render_goal_pins(goal, pin_list, shown_messages)
    lines = ["📌 #{goal.description} (id: #{goal.id})"]
    pin_list.each { |pin| lines << format_pin_line(pin, shown_messages) }
    lines.join("\n")
  end

  # Formats a single pin line with deduplication: first occurrence shows
  # truncated text, subsequent occurrences show bare message ID only.
  #
  # @param pin [PinnedMessage]
  # @param shown_messages [Set<Integer>]
  # @return [String]
  def format_pin_line(pin, shown_messages)
    mid = pin.message_id
    if shown_messages.add?(mid)
      "  message #{mid}: #{pin.display_text}"
    else
      "  message #{mid}"
    end
  end

  # Converts a chronological list of messages into Anthropic wire-format messages.
  # Prepends a compact timestamp to each user message for LLM time awareness.
  # Groups consecutive tool_call messages into one assistant message and
  # consecutive tool_response messages into one user message.
  #
  # @param msgs [Array<Message>]
  # @return [Array<Hash>]
  def assemble_messages(msgs)
    msgs.each_with_object([]) do |msg, api_messages|
      case msg.message_type
      when "user_message"
        content = "#{format_message_time(msg.timestamp)}\n#{msg.payload["content"]}"
        api_messages << {role: "user", content: content}
      when "agent_message"
        api_messages << {role: "assistant", content: msg.payload["content"].to_s}
      when "tool_call"
        append_grouped_block(api_messages, "assistant", tool_use_block(msg.payload))
      when "tool_response"
        append_grouped_block(api_messages, "user", tool_result_block(msg.payload))
      when "system_message"
        # Wrapped as user role with prefix — Claude API has no system role in conversation history
        api_messages << {role: "user", content: "[system] #{msg.payload["content"]}"}
      end
    end
  end

  # Groups consecutive tool blocks into a single message of the given role.
  def append_grouped_block(api_messages, role, block)
    prev = api_messages.last
    if prev&.dig(:role) == role && prev[:content].is_a?(Array)
      prev[:content] << block
    else
      api_messages << {role: role, content: [block]}
    end
  end

  def tool_use_block(payload)
    {
      type: "tool_use",
      id: payload["tool_use_id"],
      name: payload["tool_name"],
      input: payload["tool_input"] || {}
    }
  end

  def tool_result_block(payload)
    {
      type: "tool_result",
      tool_use_id: payload["tool_use_id"],
      content: payload["content"].to_s
    }
  end

  # Formats a message's nanosecond timestamp as a compact time prefix for LLM context.
  # Gives the agent awareness of time of day, day of week, and pauses between messages.
  #
  # @param timestamp_ns [Integer] nanoseconds since epoch
  # @return [String] e.g. "Sat Mar 14 09:51"
  # @example
  #   format_message_time(1_710_406_260_000_000_000) #=> "Thu Mar 14 09:51"
  def format_message_time(timestamp_ns)
    Time.at(timestamp_ns / 1_000_000_000.0).utc.strftime("%a %b %-d %H:%M")
  end

  # Current time as nanoseconds since epoch. Uses Time.current so
  # ActiveSupport's freeze_time works in tests.
  #
  # @return [Integer] nanoseconds since epoch
  def now_ns
    Time.current.to_ns
  end

  # Delegates to {Message#estimate_tokens} for messages not yet counted
  # by the background job.
  #
  # @param msg [Message]
  # @return [Integer] at least 1
  def estimate_tokens(msg)
    msg.estimate_tokens
  end
end
