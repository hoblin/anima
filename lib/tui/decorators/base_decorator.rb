# frozen_string_literal: true

require_relative "../formatting"

module TUI
  module Decorators
    # Client-side decorator layer for per-tool TUI rendering.
    #
    # Mirrors the server's Draper architecture but with a different
    # specialization axis: server decorators are uniform per EVENT TYPE
    # (tool_call, tool_result, message), while client decorators are
    # unique per TOOL NAME (bash, read_file, web_get) — determining
    # how each tool looks on screen.
    #
    # The factory dispatches on the +tool+ field in the structured data
    # hash received from the server. Unknown tools fall back to generic
    # rendering provided by this base class.
    #
    # @example Render a tool call
    #   decorator = TUI::Decorators::BaseDecorator.for(data)
    #   lines = decorator.render(tui)
    class BaseDecorator
      include Formatting

      ICON = "\u{1F527}"        # wrench
      CHECKMARK = "\u2713"
      RETURN_ARROW = "\u21A9"
      ERROR_ICON = "\u274C"

      attr_reader :data

      def initialize(data)
        @data = data
      end

      # Factory returning the per-tool decorator for the given data hash.
      #
      # @param data [Hash] structured event data with string keys
      #   ("role", "tool", "content", etc.)
      # @return [BaseDecorator] the appropriate per-tool decorator
      def self.for(data)
        tool = resolve_tool(data)
        decorator_for(tool).new(data)
      end

      # Renders the event, dispatching by role to the appropriate method.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render(tui)
        case data["role"].to_s
        when "tool_call" then render_call(tui)
        when "tool_response" then render_response(tui)
        when "think" then render_think(tui)
        end
      end

      # Generic tool call rendering — icon, tool name, and indented input.
      # Subclasses override for tool-specific presentation.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_call(tui)
        style = tui.style(fg: color)
        header = build_call_header
        lines = [tui.line(spans: [tui.span(content: header, style: style)])]
        data["input"].to_s.split("\n", -1).each do |line|
          lines << tui.line(spans: [tui.span(content: preserve_indentation("  #{line}"), style: style)])
        end
        lines
      end

      # Generic tool response rendering — success/failure indicator and content.
      # Token counts get their own color-coded span so expensive responses
      # visually jump out in debug mode.
      # Subclasses override for tool-specific presentation.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_response(tui)
        indicator = (data["success"] == false) ? ERROR_ICON : CHECKMARK
        tool_id = data["tool_use_id"]
        tokens = data["tokens"]
        style = tui.style(fg: response_color)

        meta_parts = []
        meta_parts << "[#{tool_id}]" if tool_id
        meta_parts << indicator
        prefix = "  #{RETURN_ARROW} #{meta_parts.join(" ")} "

        content_lines = data["content"].to_s.split("\n", -1)
        first_line_spans = [tui.span(content: prefix, style: style)]
        if tokens
          tok_label = format_token_label(tokens, data["estimated"])
          first_line_spans << tui.span(content: "#{tok_label} ", style: tui.style(fg: token_count_color(tokens)))
        end
        first_line_spans << tui.span(content: content_lines.first.to_s, style: style)

        lines = [tui.line(spans: first_line_spans)]
        content_lines.drop(1).each { |line| lines << tui.line(spans: [tui.span(content: preserve_indentation("    #{line}"), style: style)]) }
        lines
      end

      # Think rendering — delegated to ThinkDecorator, but base provides
      # a fallback that renders as a generic tool call.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_think(tui)
        render_call(tui)
      end

      # Icon for this tool type. Subclasses override with tool-specific icons.
      # @return [String]
      def icon
        ICON
      end

      # Unified color for all tool call headers. Keeps tool invocations
      # visually distinct from conversation messages (user/assistant/thought).
      # @return [String]
      def color
        Settings.theme_color_accent
      end

      # Color for tool response content. Subclasses override for tool-specific colors.
      # @return [String]
      def response_color
        Settings.theme_color_text
      end

      private

      # Builds the header line for a tool call entry.
      # @return [String]
      def build_call_header
        ts = data["timestamp"]
        tool_id = data["tool_use_id"]

        meta = []
        meta << "[#{format_ns_timestamp(ts)}]" if ts
        prefix = meta.empty? ? icon : "#{meta.join(" ")} #{icon}"
        header = "#{prefix} #{data["tool"]}"
        header += " [#{tool_id}]" if tool_id
        header
      end

      # Resolves the tool name from the data hash.
      # Think events have role "think" but no "tool" field.
      def self.resolve_tool(data)
        role = data["role"].to_s
        return "think" if role == "think"

        data["tool"].to_s
      end
      private_class_method :resolve_tool

      # Maps tool name to its decorator class.
      # Unknown tools get the base decorator (generic rendering).
      def self.decorator_for(tool_name)
        case tool_name
        when "bash" then BashDecorator
        when "think" then ThinkDecorator
        when "read_file" then ReadDecorator
        when "edit_file" then EditDecorator
        when "write_file" then WriteDecorator
        when "web_get" then WebGetDecorator
        else self
        end
      end
      private_class_method :decorator_for
    end
  end
end
