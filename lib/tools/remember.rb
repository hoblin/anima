# frozen_string_literal: true

module Tools
  # Fractal-resolution zoom into message history. Returns a window centered
  # on a target message with full detail at the center and compressed context
  # at the edges — sharp fovea, blurry periphery.
  #
  # Output structure:
  #   [Previous snapshots — compressed context before]
  #   [Messages N-M — full detail, tool_responses compressed to checkmarks]
  #   [Following snapshots — compressed context after]
  #
  # The agent discovers target messages via FTS5 search results embedded in
  # viewport recall snippets. This tool drills down into the full context.
  #
  # @example
  #   remember(message_id: 42)
  class Remember < Base
    # Messages around the target to include at full resolution.
    # ±10 messages provides sharp foveal detail while keeping output readable.
    CONTEXT_WINDOW = 20

    ROLE_LABELS = {
      "user_message" => "User",
      "agent_message" => "Assistant",
      "system_message" => "System"
    }.freeze

    def self.tool_name = "remember"

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

    # @param input [Hash] with "message_id"
    # @return [String] fractal-resolution window around the target message
    def execute(input)
      message_id = input["message_id"].to_i
      target = Message.find_by(id: message_id)
      return {error: "Message #{message_id} not found"} unless target

      build_fractal_window(target)
    end

    private

    # Assembles the three-zone fractal window.
    #
    # @param target [Message] the center message
    # @return [String] formatted fractal window
    def build_fractal_window(target)
      target_session = target.session
      center_messages = fetch_center_messages(target, target_session)
      first_center_id = center_messages.first&.id
      last_center_id = center_messages.last&.id

      sections = build_sections(
        target_session: target_session,
        center_messages: center_messages,
        target_id: target.id,
        first_center_id: first_center_id,
        last_center_id: last_center_id
      )
      sections.join("\n")
    end

    # Builds ordered sections: header, before snapshots, center, after snapshots.
    def build_sections(target_session:, center_messages:, target_id:, first_center_id:, last_center_id:)
      sections = [session_header(target_session)]

      append_snapshot_sections(sections, target_session.snapshots
        .where("to_message_id < ?", first_center_id)
        .chronological.last(3), label: "PREVIOUS CONTEXT")

      sections << "── FULL CONTEXT (messages #{first_center_id}..#{last_center_id}) ──"
      center_messages.each { |msg| sections << render_center_message(msg, target_id) }

      append_snapshot_sections(sections, target_session.snapshots
        .where("from_message_id > ?", last_center_id)
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

    # Fetches conversation messages around the target within a fixed window.
    #
    # @return [Array<Message>] chronologically ordered
    def fetch_center_messages(target, target_session)
      half = CONTEXT_WINDOW / 2
      scope = target_session.messages.context_messages
      target_id = target.id

      before = scope.where("id <= ?", target_id).reorder(id: :desc).limit(half + 1).to_a.reverse
      after = scope.where("id > ?", target_id).reorder(id: :asc).limit(half).to_a

      before + after
    end

    # Renders a center message at full resolution.
    # Conversation messages show full content. Tool calls show name + input.
    # Tool responses compressed to status indicator.
    #
    # @param message [Message]
    # @param target_id [Integer] the message being zoomed into (marked with arrow)
    # @return [String]
    def render_center_message(message, target_id)
      marker = (message.id == target_id) ? "→" : " "
      prefix = "#{marker} message #{message.id}"

      "#{prefix} #{format_message_content(message)}"
    end

    # Formats message content based on type.
    def format_message_content(message)
      data = message.payload
      content = data["content"]

      if ROLE_LABELS.key?(message.message_type)
        "#{ROLE_LABELS[message.message_type]}: #{content}"
      elsif message.message_type == "tool_call"
        format_tool_call(data)
      elsif message.message_type == "tool_response"
        status = content.to_s.start_with?("Error") ? "error" : "ok"
        "ToolResult: [#{status}] #{data["tool_use_id"]}"
      end
    end

    def format_tool_call(data)
      if data["tool_name"] == Message::THINK_TOOL
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
      "[#{level} snapshot, messages #{snapshot.from_message_id}..#{snapshot.to_message_id}]\n#{snapshot.text}"
    end
  end
end
