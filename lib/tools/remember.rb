# frozen_string_literal: true

module Tools
  # Fractal-resolution zoom into event history. Returns a window centered
  # on a target event with full detail at the center and compressed context
  # at the edges — sharp fovea, blurry periphery.
  #
  # Output structure:
  #   [Previous snapshots — compressed context before]
  #   [Events N-M — full detail, tool_responses compressed to checkmarks]
  #   [Following snapshots — compressed context after]
  #
  # The agent discovers target events via FTS5 search results embedded in
  # viewport recall snippets. This tool drills down into the full context.
  #
  # @example
  #   remember(event_id: 42)
  class Remember < Base
    # Events around the target to include at full resolution.
    # ±10 events provides sharp foveal detail while keeping output readable.
    CONTEXT_WINDOW = 20

    ROLE_LABELS = {
      "user_message" => "User",
      "agent_message" => "Assistant",
      "system_message" => "System"
    }.freeze

    def self.tool_name = "remember"

    # Exposed as `message_id` in the tool schema for natural agent UX,
    # mapped to `event_id` internally since events are the persistence layer.
    def self.description = "Recall the full conversation around a past message."

    def self.input_schema
      {
        type: "object",
        properties: {
          message_id: {type: "integer"}
        },
        required: ["message_id"]
      }
    end

    def initialize(session:, **)
      @session = session
    end

    # @param input [Hash] with "message_id" (maps to internal event ID)
    # @return [String] fractal-resolution window around the target message
    def execute(input)
      event_id = input["message_id"].to_i
      target = Event.find_by(id: event_id)
      return {error: "Event #{event_id} not found"} unless target

      build_fractal_window(target)
    end

    private

    # Assembles the three-zone fractal window.
    #
    # @param target [Event] the center event
    # @return [String] formatted fractal window
    def build_fractal_window(target)
      target_session = target.session
      center_events = fetch_center_events(target, target_session)
      first_center_id = center_events.first&.id
      last_center_id = center_events.last&.id

      sections = build_sections(
        target_session: target_session,
        center_events: center_events,
        target_id: target.id,
        first_center_id: first_center_id,
        last_center_id: last_center_id
      )
      sections.join("\n")
    end

    # Builds ordered sections: header, before snapshots, center, after snapshots.
    def build_sections(target_session:, center_events:, target_id:, first_center_id:, last_center_id:)
      sections = [session_header(target_session)]

      append_snapshot_sections(sections, target_session.snapshots
        .where("to_event_id < ?", first_center_id)
        .chronological.last(3), label: "PREVIOUS CONTEXT")

      sections << "── FULL CONTEXT (events #{first_center_id}..#{last_center_id}) ──"
      center_events.each { |event| sections << render_center_event(event, target_id) }

      append_snapshot_sections(sections, target_session.snapshots
        .where("from_event_id > ?", last_center_id)
        .chronological.first(3), label: "FOLLOWING CONTEXT")

      sections
    end

    def session_header(target_session)
      label = target_session.name || "Session ##{target_session.id}"
      "── recalled from: #{label} ──"
    end

    # Appends snapshot sections if any exist.
    def append_snapshot_sections(sections, snapshots, label:)
      return if snapshots.empty?

      sections << "── #{label} (compressed) ──"
      snapshots.each { |snapshot| sections << format_snapshot(snapshot) }
    end

    # Fetches conversation events around the target within a fixed window.
    #
    # @return [Array<Event>] chronologically ordered
    def fetch_center_events(target, target_session)
      half = CONTEXT_WINDOW / 2
      scope = target_session.events.context_events.deliverable
      target_id = target.id

      before = scope.where("id <= ?", target_id).reorder(id: :desc).limit(half + 1).to_a.reverse
      after = scope.where("id > ?", target_id).reorder(id: :asc).limit(half).to_a

      before + after
    end

    # Renders a center event at full resolution.
    # Conversation events show full content. Tool calls show name + input.
    # Tool responses compressed to status indicator.
    #
    # @param event [Event]
    # @param target_id [Integer] the event being zoomed into (marked with arrow)
    # @return [String]
    def render_center_event(event, target_id)
      marker = (event.id == target_id) ? "→" : " "
      prefix = "#{marker} event #{event.id}"

      "#{prefix} #{format_event_content(event)}"
    end

    # Formats event content based on type.
    def format_event_content(event)
      data = event.payload
      content = data["content"]

      if ROLE_LABELS.key?(event.event_type)
        "#{ROLE_LABELS[event.event_type]}: #{content}"
      elsif event.event_type == "tool_call"
        format_tool_call(data)
      elsif event.event_type == "tool_response"
        status = content.to_s.start_with?("Error") ? "error" : "ok"
        "ToolResult: [#{status}] #{data["tool_use_id"]}"
      end
    end

    def format_tool_call(data)
      if data["tool_name"] == Event::THINK_TOOL
        "Think: #{data.dig("tool_input", "thoughts")}"
      else
        "Tool: #{data["tool_name"]}(#{data["tool_input"].to_json.truncate(200)})"
      end
    end

    # Formats a snapshot as compressed context.
    #
    # @param snapshot [Snapshot]
    # @return [String]
    def format_snapshot(snapshot)
      level = (snapshot.level == 2) ? "L2" : "L1"
      "[#{level} snapshot, events #{snapshot.from_event_id}..#{snapshot.to_event_id}]\n#{snapshot.text}"
    end
  end
end
