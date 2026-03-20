# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Event} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
#
# Sessions form a hierarchy: a main session can spawn child sessions
# (sub-agents) that inherit the parent's viewport context at fork time.
class Session < ApplicationRecord
  class MissingSoulError < StandardError; end

  VIEW_MODES = %w[basic verbose debug].freeze

  serialize :granted_tools, coder: JSON

  has_many :events, -> { order(:id) }, dependent: :destroy
  has_many :goals, dependent: :destroy

  belongs_to :parent_session, class_name: "Session", optional: true
  has_many :child_sessions, class_name: "Session", foreign_key: :parent_session_id, dependent: :destroy

  validates :view_mode, inclusion: {in: VIEW_MODES}
  validates :name, length: {maximum: 255}, allow_nil: true

  after_update_commit :broadcast_name_update, if: :saved_change_to_name?
  after_update_commit :broadcast_active_skills_update, if: :saved_change_to_active_skills?
  after_update_commit :broadcast_active_workflow_update, if: :saved_change_to_active_workflow?

  scope :recent, ->(limit = 10) { order(updated_at: :desc).limit(limit) }
  scope :root_sessions, -> { where(parent_session_id: nil) }

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

    count = events.llm_messages.count
    return if count < 2
    # Already named — only regenerate at interval boundaries (30, 60, 90, …)
    return if name.present? && (count % Anima::Settings.name_generation_interval != 0)

    AnalyticalBrainJob.perform_later(id)
  end

  # Returns the events currently visible in the LLM context window.
  # Walks events newest-first and includes them until the token budget
  # is exhausted. Events are full-size or excluded entirely.
  #
  # Sub-agent sessions inherit parent context via virtual viewport:
  # child events are prioritized and fill the budget first (newest-first),
  # then parent events from before the fork point fill the remaining budget.
  # The final array is chronological: parent events first, then child events.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @param include_pending [Boolean] whether to include pending messages (true for
  #   display, false for LLM context assembly)
  # @return [Array<Event>] chronologically ordered
  def viewport_events(token_budget: Anima::Settings.token_budget, include_pending: true)
    own_events = select_events(own_event_scope(include_pending), budget: token_budget)
    remaining = token_budget - own_events.sum { |e| event_token_cost(e) }

    if sub_agent? && remaining > 0
      parent_events = select_events(parent_event_scope(include_pending), budget: remaining)
      trim_trailing_tool_calls(parent_events) + own_events
    else
      own_events
    end
  end

  # Recalculates the viewport and returns IDs of events evicted since the
  # last snapshot. Updates the stored viewport_event_ids atomically.
  # Piggybacks on event broadcasts to notify clients which messages left
  # the LLM's context window.
  #
  # @return [Array<Integer>] IDs of events no longer in the viewport
  def recalculate_viewport!
    new_ids = viewport_events.map(&:id)
    old_ids = viewport_event_ids

    evicted = old_ids - new_ids
    update_column(:viewport_event_ids, new_ids) if old_ids != new_ids
    evicted
  end

  # Overwrites the viewport snapshot without computing evictions.
  # Used when transmitting or broadcasting a full viewport refresh,
  # where eviction notifications are unnecessary (clients clear their
  # store first).
  #
  # @param ids [Array<Integer>] event IDs now in the viewport
  # @return [void]
  def snapshot_viewport!(ids)
    update_column(:viewport_event_ids, ids)
  end

  # Returns the system prompt for this session.
  # Sub-agent sessions use their stored prompt. Main sessions assemble
  # a system prompt from active skills and current goals.
  #
  # @param environment_context [String, nil] pre-assembled environment block
  #   from {EnvironmentProbe}; injected between soul and expertise sections
  # @return [String, nil] the system prompt text, or nil when nothing to inject
  def system_prompt(environment_context: nil)
    sub_agent? ? prompt : assemble_system_prompt(environment_context: environment_context)
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

  # Assembles the system prompt: soul first, then environment context,
  # then skills/workflow, then goals.
  # The soul is always present — "who am I" before "what can I do."
  #
  # @param environment_context [String, nil] pre-assembled environment block
  # @return [String] composed system prompt
  def assemble_system_prompt(environment_context: nil)
    [assemble_soul_section, environment_context, assemble_expertise_section, assemble_goals_section].compact.join("\n\n")
  end

  # Serializes active goals as a lightweight summary for ActionCable
  # broadcasts and TUI display. Returns a nested structure: root goals
  # with their sub-goals inlined.
  #
  # @return [Array<Hash>] each with :id, :description, :status, and :sub_goals
  def goals_summary
    goals.root.includes(:sub_goals).order(:created_at).map(&:as_summary)
  end

  # Builds the message array expected by the Anthropic Messages API.
  # Includes user/agent messages and tool call/response events in
  # Anthropic's wire format. Consecutive tool_call events are grouped
  # into a single assistant message; consecutive tool_response events
  # are grouped into a single user message with tool_result blocks.
  # Pending messages are excluded — they haven't been delivered yet.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Hash>] Anthropic Messages API format
  def messages_for_llm(token_budget: Anima::Settings.token_budget)
    assemble_messages(viewport_events(token_budget: token_budget, include_pending: false))
  end

  # Promotes all pending user messages to delivered status so they
  # appear in the next LLM context. Triggers broadcast_update for
  # each event so connected clients refresh the pending indicator.
  #
  # @return [Integer] number of promoted messages
  def promote_pending_messages!
    promoted = 0
    events.where(event_type: "user_message", status: Event::PENDING_STATUS).find_each do |event|
      event.update!(status: nil, payload: event.payload.except("status"))
      promoted += 1
    end
    promoted
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
      "children" => children.map { |child| {"id" => child.id, "name" => child.name, "processing" => child.processing?} }
    })
  end

  private

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

  # Assembles the goals section of the system prompt.
  # Active root goals render as `###` headings with sub-goal checkboxes.
  # Completed root goals collapse to a single strikethrough line.
  #
  # @return [String, nil] goals section, or nil when no goals exist
  def assemble_goals_section
    root_goals = goals.root.includes(:sub_goals).order(:created_at)
    return if root_goals.empty?

    entries = root_goals.map { |goal| render_goal_markdown(goal) }
    "## Current Goals\n\n#{entries.join("\n\n")}"
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

  # Scopes own events for viewport assembly.
  # @return [ActiveRecord::Relation]
  def own_event_scope(include_pending)
    scope = events.context_events
    include_pending ? scope : scope.deliverable
  end

  # Scopes parent events created before this session's fork point.
  # @return [ActiveRecord::Relation]
  def parent_event_scope(include_pending)
    scope = parent_session.events.context_events.where(created_at: ...created_at)
    include_pending ? scope : scope.deliverable
  end

  # Walks events newest-first, selecting until the token budget is exhausted.
  # Always includes at least the newest event even if it exceeds budget.
  #
  # @param scope [ActiveRecord::Relation] event scope to select from
  # @param budget [Integer] maximum tokens to include
  # @return [Array<Event>] chronologically ordered
  def select_events(scope, budget:)
    selected = []
    remaining = budget

    scope.reorder(id: :desc).each do |event|
      cost = event_token_cost(event)
      break if cost > remaining && selected.any?

      selected << event
      remaining -= cost
    end

    selected.reverse
  end

  # @return [Integer] token cost, using cached count or heuristic estimate
  def event_token_cost(event)
    (event.token_count > 0) ? event.token_count : estimate_tokens(event)
  end

  # Removes trailing tool_call events that lack matching tool_response.
  # Prevents orphaned tool_use blocks at the parent/child viewport boundary
  # (the spawn_subagent/spawn_specialist tool_call is emitted before the child exists,
  # but its tool_response comes after — so the cutoff can split them).
  def trim_trailing_tool_calls(event_list)
    event_list.pop while event_list.last&.event_type == "tool_call"
    event_list
  end

  # Converts a chronological list of events into Anthropic wire-format messages.
  # Prepends a compact timestamp to each user message for LLM time awareness.
  # Groups consecutive tool_call events into one assistant message and
  # consecutive tool_response events into one user message.
  #
  # @param events [Array<Event>]
  # @return [Array<Hash>]
  def assemble_messages(events)
    events.each_with_object([]) do |event, messages|
      case event.event_type
      when "user_message"
        content = "#{format_event_time(event.timestamp)}\n#{event.payload["content"]}"
        messages << {role: "user", content: content}
      when "agent_message"
        messages << {role: "assistant", content: event.payload["content"].to_s}
      when "tool_call"
        append_grouped_block(messages, "assistant", tool_use_block(event.payload))
      when "tool_response"
        append_grouped_block(messages, "user", tool_result_block(event.payload))
      when "system_message"
        # Wrapped as user role with prefix — Claude API has no system role in conversation history
        messages << {role: "user", content: "[system] #{event.payload["content"]}"}
      end
    end
  end

  # Groups consecutive tool blocks into a single message of the given role.
  def append_grouped_block(messages, role, block)
    prev = messages.last
    if prev&.dig(:role) == role && prev[:content].is_a?(Array)
      prev[:content] << block
    else
      messages << {role: role, content: [block]}
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

  # Formats an event's nanosecond timestamp as a compact time prefix for LLM context.
  # Gives the agent awareness of time of day, day of week, and pauses between messages.
  #
  # @param timestamp_ns [Integer] nanoseconds since epoch
  # @return [String] e.g. "Sat Mar 14 09:51"
  # @example
  #   format_event_time(1_710_406_260_000_000_000) #=> "Thu Mar 14 09:51"
  def format_event_time(timestamp_ns)
    Time.at(timestamp_ns / 1_000_000_000.0).strftime("%a %b %-d %H:%M")
  end

  # Delegates to {Event#estimate_tokens} for events not yet counted
  # by the background job.
  #
  # @param event [Event]
  # @return [Integer] at least 1
  def estimate_tokens(event)
    event.estimate_tokens
  end
end
