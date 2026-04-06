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

  # @return [Boolean] true if this session is a sub-agent (has a parent)
  def sub_agent?
    parent_session_id.present?
  end

  # Checks whether the Mneme boundary has left the viewport and enqueues
  # {MnemeJob} when it has. Delegates initial boundary placement to
  # {#initialize_mneme_boundary!} on the first call.
  #
  # @return [void]
  def schedule_mneme!
    return if sub_agent?

    if mneme_boundary_message_id.nil?
      initialize_mneme_boundary!
      return
    end

    return if viewport_message_ids.include?(mneme_boundary_message_id)

    MnemeJob.perform_later(id)
  end

  # Places the initial Mneme boundary at the oldest eligible message in
  # the session — the top of the raw window, from which Mneme will start
  # compressing downward once that message drifts out of the viewport.
  # Eligible messages are conversation messages (user/agent/system) and
  # think tool_calls, considered on equal footing; bare tool_call or
  # tool_response messages are never eligible.
  #
  # No-op when the session has no eligible messages yet.
  #
  # @return [void]
  def initialize_mneme_boundary!
    first_id = messages
      .where(message_type: Message::CONVERSATION_TYPES)
      .or(messages.where(message_type: "tool_call")
        .where("json_extract(payload, '$.tool_name') = ?", Message::THINK_TOOL))
      .order(:id)
      .pick(:id)

    update_column(:mneme_boundary_message_id, first_id) if first_id
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

  # Token budget appropriate for this session type.
  # Sub-agents use a smaller budget to stay out of the "dumb zone".
  # @return [Integer]
  def effective_token_budget
    sub_agent? ? Anima::Settings.subagent_token_budget : Anima::Settings.token_budget
  end

  # Returns the messages currently visible in the LLM context window as a
  # composable AR relation. Selects own messages above the Mneme boundary
  # whose cumulative token count (walked newest-first) fits within the
  # budget. The newest message is always included even when it alone
  # exceeds the budget. Messages are full-size or excluded entirely.
  #
  # The selection runs as a single SQL query using a window function
  # ({+SUM() OVER+}). Older messages have been compressed into snapshots
  # and no longer participate in the viewport. Pending messages live in a
  # separate table ({PendingMessage}) and never appear here — they are
  # promoted to real messages before the agent processes them.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [ActiveRecord::Relation<Message>] chronologically ordered by id
  def viewport_messages(token_budget: effective_token_budget)
    scope = messages
    scope = scope.where("messages.id >= ?", mneme_boundary_message_id) if mneme_boundary_message_id

    windowed = scope.select(
      "messages.*",
      "SUM(token_count) OVER (ORDER BY id DESC) AS running_total"
    )

    Message
      .from(Arel.sql("(#{windowed.to_sql}) AS messages"))
      .where("running_total <= ? OR running_total = token_count", token_budget)
      .order(:id)
  end

  # Recalculates the viewport and returns IDs of messages evicted since the
  # last snapshot. Updates the stored viewport_message_ids atomically.
  # Piggybacks on message broadcasts to notify clients which messages left
  # the LLM's context window.
  #
  # @return [Array<Integer>] IDs of messages no longer in the viewport
  def recalculate_viewport!
    new_ids = viewport_messages.pluck(:id)
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

  # Returns skill names whose recalled content is currently visible in the
  # viewport. Used by the analytical brain for deduplication — skills already
  # in the viewport are excluded from the activation catalog.
  #
  # @return [Set<String>] skill names present in the viewport
  def skills_in_viewport
    recalled_sources_in_viewport("skill")
  end

  # Returns the workflow name currently visible in the viewport, if any.
  # Only one workflow can be active at a time, so we return the first match.
  #
  # @return [String, nil] workflow name present in the viewport
  def workflow_in_viewport
    recalled_sources_in_viewport("workflow").first
  end

  # Returns the system prompt for this session.
  # Sub-agent sessions use their stored prompt plus active skills and
  # the pinned task. Main sessions assemble a full system prompt from
  # soul and snapshots. Skills, workflows, and goals are injected as
  # phantom tool_use/tool_result pairs in the message stream (not here)
  # to keep the system prompt stable for prompt caching. Environment
  # awareness flows through Bash tool responses.
  #
  # Sub-agent sessions still include expertise inline — they're short-lived
  # and don't benefit from prompt caching.
  #
  # @return [String, nil] the system prompt text, or nil when nothing to inject
  def system_prompt
    if sub_agent?
      [prompt, assemble_expertise_section, assemble_task_section].compact.join("\n\n")
    else
      assemble_system_prompt
    end
  end

  # Activates a skill on this session. Validates the skill exists in the
  # registry, updates active_skills, and enqueues the skill content as a
  # {PendingMessage} so it enters the conversation as a phantom
  # tool_use/tool_result pair through the normal promotion flow.
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
    enqueue_recall_message("skill", skill_name, definition.content)
    definition
  end

  # Deactivates a skill on this session. Removes it from active_skills and persists.
  # The skill's recalled message stays in the conversation and evicts naturally.
  #
  # @param skill_name [String] name of the skill to deactivate
  # @return [void]
  def deactivate_skill(skill_name)
    return unless active_skills.include?(skill_name)

    self.active_skills = active_skills - [skill_name]
    save!
  end

  # Activates a workflow on this session. Validates the workflow exists in the
  # registry, sets it as the active workflow, and enqueues the workflow content
  # as a {PendingMessage}. Only one workflow can be active at a time —
  # activating a new one replaces the previous.
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
    enqueue_recall_message("workflow", workflow_name, definition.content)
    definition
  end

  # Deactivates the current workflow on this session.
  # The workflow's recalled message stays in the conversation and evicts naturally.
  #
  # @return [void]
  def deactivate_workflow
    return unless active_workflow.present?

    self.active_workflow = nil
    save!
  end

  # Assembles the system prompt: version preamble, soul, and snapshots.
  # Skills, workflows, goals, and environment awareness flow through the
  # message stream and tool responses, keeping the system prompt stable
  # for prompt caching.
  #
  # @return [String] composed system prompt
  def assemble_system_prompt
    [assemble_version_preamble, assemble_soul_section, assemble_snapshots_section]
      .compact.join("\n\n")
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
  #   [context prefix: goals + pinned messages] [sliding window messages]
  #
  # Snapshots live in the system prompt (stable between Mneme runs).
  # Goal events and recalled memories flow through the message stream as
  # phantom tool pairs — they ride the conveyor belt as regular messages.
  # After eviction, a goal snapshot + pinned messages block is rebuilt
  # from DB state and prepended as a phantom pair.
  #
  # The sliding window is post-processed by {#ensure_atomic_tool_pairs}
  # which removes orphaned tool messages whose partner was cut off by the
  # token budget.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Hash>] Anthropic Messages API format
  def messages_for_llm(token_budget: effective_token_budget)
    heal_orphaned_tool_calls!

    sliding_budget = token_budget

    pinned_budget = (token_budget * Anima::Settings.mneme_pinned_budget_fraction).to_i
    sliding_budget -= pinned_budget

    window = viewport_messages(token_budget: sliding_budget).to_a
    first_message_id = window.first&.id

    prefix = assemble_context_prefix_messages(first_message_id, budget: pinned_budget)

    prefix + assemble_messages(ensure_atomic_tool_pairs(window))
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

  # Promotes a phantom pair pending message into a tool_call/tool_response pair.
  # These persist as real Message records and ride the conveyor belt.
  #
  # @param pm [PendingMessage] phantom pair pending message
  # @return [void]
  def promote_phantom_pair!(pm)
    tool_name = pm.phantom_tool_name
    tool_input = pm.phantom_tool_input
    uid = "#{tool_name}_#{pm.id}"
    now = now_ns

    messages.create!(
      message_type: "tool_call",
      tool_use_id: uid,
      payload: {"tool_name" => tool_name, "tool_use_id" => uid,
                "tool_input" => tool_input.stringify_keys,
                "content" => pm.display_content.lines.first.chomp},
      timestamp: now,
      token_count: Mneme::PassiveRecall::TOOL_PAIR_OVERHEAD_TOKENS
    )

    messages.create!(
      message_type: "tool_response",
      tool_use_id: uid,
      payload: {"tool_name" => tool_name, "tool_use_id" => uid,
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
  # @param source_type [String, nil] origin type (e.g. "skill", "workflow")
  #   for viewport tracking; omitted for plain user messages
  # @param source_name [String, nil] origin name (e.g. skill name)
  # @return [Message] the persisted message record
  def create_user_message(content, source_type: nil, source_name: nil)
    now = now_ns
    payload = {type: "user_message", content: content, session_id: id, timestamp: now}
    payload["source_type"] = source_type if source_type
    payload["source_name"] = source_name if source_name
    messages.create!(
      message_type: "user_message",
      payload: payload,
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
  # - +:pairs+ — synthetic tool_use/tool_result message hashes for phantom pair
  #   types (appended as new conversation turns)
  #
  # @return [Hash{Symbol => Array}] promoted messages split by injection strategy
  def promote_pending_messages!
    texts = []
    pairs = []
    pending_messages.find_each do |pm|
      transaction do
        if pm.phantom_pair?
          promote_phantom_pair!(pm)
        else
          create_user_message(pm.display_content, source_type: pm.source_type, source_name: pm.source_name)
        end
        pm.destroy!
      end
      if pm.phantom_pair?
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

  # Finds recalled skill/workflow source names in the current viewport.
  # Scans viewport messages for user_messages tagged with the given source_type.
  #
  # @param source_type [String] "skill" or "workflow"
  # @return [Set<String>] source names present in the viewport
  def recalled_sources_in_viewport(source_type)
    ids = viewport_message_ids
    return Set.new if ids.empty?

    messages
      .where(id: ids, message_type: "user_message")
      .where("json_extract(payload, '$.source_type') = ?", source_type)
      .pluck(Arel.sql("json_extract(payload, '$.source_name')"))
      .to_set
  end

  # Enqueues a recalled skill or workflow as a {PendingMessage}.
  # Always goes through the pending queue because the analytical brain
  # only runs during processing. The message enters the conversation
  # through the normal promotion flow as a phantom tool_use/tool_result pair.
  #
  # @param source_type [String] "skill" or "workflow"
  # @param source_name [String] skill or workflow name
  # @param content [String] definition content to recall
  # @return [PendingMessage] the created pending message
  def enqueue_recall_message(source_type, source_name, content)
    pending_messages.create!(content: content, source_type: source_type, source_name: source_name)
  end

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

  # Ensures every tool_call in the message list has a matching tool_response
  # (and vice versa) by removing unpaired messages. The Anthropic API requires
  # every tool_use block to have a tool_result — a missing partner causes
  # a permanent API error. Token budget cutoffs can split pairs when the
  # boundary falls between a tool_call and its tool_response.
  #
  # Still necessary even though {#assemble_messages} pairs by +tool_use_id+:
  # the assembly assumes every tool_call has a matching response in the window.
  # This guard ensures that assumption holds after viewport truncation.
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

  # Assembles the context prefix: active goals snapshot + pinned messages.
  # Only shown after the first eviction — before that, goal events flow
  # as phantom pairs in the message stream and pinned messages have not
  # yet evicted.
  #
  # Returns a phantom tool_call/tool_result pair so the LLM sees a
  # coherent goals + pins block it "recalled" via a tool invocation.
  #
  # @param first_message_id [Integer, nil] first message ID in the sliding window
  # @param budget [Integer] token budget for context prefix
  # @return [Array<Hash>] Anthropic Messages API format (0 or 2 messages)
  def assemble_context_prefix_messages(first_message_id, budget:)
    return [] unless first_message_id
    return [] unless messages.where("id < ?", first_message_id).exists?

    root_goals = goals.root.active.includes(:sub_goals).order(:created_at)
    return [] if root_goals.empty?

    pins = pinned_messages
      .includes(:message, :goals)
      .where("pinned_messages.message_id < ?", first_message_id)
      .order("pinned_messages.message_id")

    selected_pins = select_pins_within_budget(pins, budget)
    content = render_goal_snapshot_with_pins(root_goals, selected_pins)

    # Uses session ID (not PendingMessage ID) because this snapshot is
    # rebuilt from DB state on every eviction — it has no stable PM record.
    uid = "goal_snapshot_#{id}"
    [
      {role: "assistant", content: [
        {type: "tool_use", id: uid, name: PendingMessage::RECALL_GOAL_TOOL, input: {}}
      ]},
      {role: "user", content: [
        {type: "tool_result", tool_use_id: uid, content: content}
      ]}
    ]
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

  # Renders active goals with their associated pinned messages as a
  # combined snapshot. Each goal shows its sub-goals and any pinned
  # messages attached to it.
  #
  # @param root_goals [Array<Goal>] active root goals with preloaded sub_goals
  # @param pins [Array<PinnedMessage>] selected pins with preloaded goals
  # @return [String] formatted goals + pins block
  def render_goal_snapshot_with_pins(root_goals, pins)
    pin_groups = group_pins_by_active_goal(pins)
    shown_messages = Set.new

    sections = root_goals.map { |goal|
      lines = [render_goal_markdown(goal)]
      goal_pins = pin_groups[goal]
      if goal_pins
        lines << ""
        goal_pins.each { |pin| lines << format_pin_line(pin, shown_messages) }
      end
      lines.join("\n")
    }

    "Current Goals\n=============\n\n#{sections.join("\n\n")}"
  end

  # Groups pins by their active Goals so the viewport renders
  # one headed section per Goal. Relies on +:goals+ being eager-loaded
  # on each pin — without it, +active_goal_pin_pairs+ triggers N+1.
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

  # Formats a single pin line with deduplication: first occurrence shows
  # truncated text, subsequent occurrences show bare message ID only.
  #
  # @param pin [PinnedMessage]
  # @param shown_messages [Set<Integer>]
  # @return [String]
  def format_pin_line(pin, shown_messages)
    mid = pin.message_id
    if shown_messages.add?(mid)
      "  📌 message #{mid}: #{pin.display_text}"
    else
      "  📌 message #{mid}"
    end
  end

  # Converts a chronological list of messages into Anthropic wire-format messages.
  # Prepends a compact timestamp to each user message for LLM time awareness.
  #
  # Tool pairing uses +tool_use_id+ lookup, not message order. When a batch
  # of consecutive +tool_call+ messages is encountered, all matching
  # +tool_response+ messages are found by +tool_use_id+ and emitted as a
  # single user message immediately after the assistant message. This
  # guarantees correct API structure even when responses are persisted
  # out of order (e.g. parallel tool execution, interleaved sub-agent
  # deliveries, or promoted pending messages).
  #
  # Assumes +ensure_atomic_tool_pairs+ has already removed any unpaired
  # tool messages from the window.
  #
  # @param msgs [Array<Message>] chronologically ordered (by id), pre-filtered
  # @return [Array<Hash>] Anthropic API message format
  def assemble_messages(msgs)
    response_index = build_tool_response_index(msgs)

    result = []
    i = 0
    while i < msgs.length
      msg = msgs[i]

      case msg.message_type
      when "user_message"
        result << {role: "user", content: "#{format_message_time(msg.timestamp)}\n#{msg.payload["content"]}"}
        i += 1
      when "agent_message"
        result << {role: "assistant", content: msg.payload["content"].to_s}
        i += 1
      when "tool_call"
        i = assemble_tool_pair(msgs, i, response_index, result)
      when "tool_response"
        # Already emitted by assemble_tool_pair via tool_use_id lookup.
        # Any response still here was orphaned by viewport eviction
        # and should have been stripped by ensure_atomic_tool_pairs.
        i += 1
      when "system_message"
        result << {role: "user", content: "[system] #{msg.payload["content"]}"}
        i += 1
      else
        i += 1
      end
    end

    result
  end

  # Collects a batch of consecutive tool_call messages starting at +start+,
  # emits one assistant message with all tool_use blocks, then emits one
  # user message with matching tool_result blocks found by tool_use_id.
  #
  # @param msgs [Array<Message>] the full message list
  # @param start [Integer] index of the first tool_call in the batch
  # @param response_index [Hash{String => Message}] tool_use_id → tool_response
  # @param result [Array<Hash>] accumulator for assembled API messages
  # @return [Integer] index of the first message after the batch
  def assemble_tool_pair(msgs, start, response_index, result)
    # Collect consecutive tool_calls (same LLM turn)
    batch = []
    i = start
    while i < msgs.length && msgs[i].message_type == "tool_call"
      batch << msgs[i]
      i += 1
    end

    # Assistant message: all tool_use blocks
    result << {role: "assistant", content: batch.map { |tc| tool_use_block(tc.payload) }}

    # User message: matching tool_result blocks, paired by tool_use_id
    tool_results = batch.filter_map do |tc|
      response = response_index[tc.tool_use_id]
      next unless response
      tool_result_block(response.payload)
    end
    result << {role: "user", content: tool_results} if tool_results.any?

    i
  end

  # Builds a hash mapping tool_use_id → tool_response Message for O(1) lookup.
  #
  # @param msgs [Array<Message>]
  # @return [Hash{String => Message}]
  def build_tool_response_index(msgs)
    msgs.each_with_object({}) do |msg, idx|
      idx[msg.tool_use_id] = msg if msg.message_type == "tool_response"
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
end
