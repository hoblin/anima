# frozen_string_literal: true

require "tempfile"

module Tools
  # Truncates oversized tool results to protect the agent's context window.
  #
  # When a tool returns more characters than the configured threshold,
  # saves the full output to a temp file and returns a truncated version:
  # first 10 lines + notice + last 10 lines. The agent can use the
  # +read_file+ tool with offset/limit to inspect the full output.
  #
  # Two thresholds exist:
  # - **Tool threshold** (~3000 chars) — for raw tool output (bash, web, etc.)
  # - **Sub-agent threshold** (~24000 chars) — for curated sub-agent results
  #
  # @example Truncating a tool result
  #   ResponseTruncator.truncate(huge_string, threshold: 3000)
  #   # => "line 1\nline 2\n...\n---\n⚠️ Response truncated..."
  module ResponseTruncator
    HEAD_LINES = 10
    TAIL_LINES = 10

    # Attribution prefix for messages routed from sub-agent to parent.
    # Shared by {Events::Subscribers::SubagentMessageRouter} and
    # {Tools::MarkGoalCompleted} to keep formatting consistent.
    ATTRIBUTION_FORMAT = "[sub-agent @%s]: %s"

    NOTICE = <<~NOTICE.strip
      ---
      ⚠️ Response truncated (%<total>d lines total). Full output saved to: %<path>s
      Use `read_file` tool with offset/limit to inspect specific sections.
      ---
    NOTICE

    # Truncates content that exceeds the character threshold.
    #
    # @param content [Object] the tool result to (maybe) truncate; non-strings pass through unchanged
    # @param threshold [Integer] character limit before truncation kicks in
    # @return [Object] original value if non-String/under threshold/few lines, truncated String otherwise
    def self.truncate(content, threshold:)
      return content unless content.is_a?(String)
      return content if content.length <= threshold

      lines = content.lines
      total = lines.size
      return content if total <= HEAD_LINES + TAIL_LINES

      path = save_full_output(content)
      head = lines.first(HEAD_LINES).join
      tail = lines.last(TAIL_LINES).join
      notice = format(NOTICE, total: total, path: path)

      "#{head}\n#{notice}\n\n#{tail}"
    end

    # Saves full content to a temp file that persists until system cleanup.
    #
    # @param content [String] the full tool result
    # @return [String] absolute path to the saved file
    def self.save_full_output(content)
      file = Tempfile.create(["tool_result_", ".txt"])
      file.write(content)
      file.close
      file.path
    end
  end
end
