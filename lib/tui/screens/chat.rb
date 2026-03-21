# frozen_string_literal: true

require_relative "../input_buffer"
require_relative "../flash"
require_relative "../decorators/base_decorator"
require_relative "../decorators/bash_decorator"
require_relative "../decorators/read_decorator"
require_relative "../decorators/edit_decorator"
require_relative "../decorators/write_decorator"
require_relative "../decorators/web_get_decorator"
require_relative "../decorators/think_decorator"
require_relative "../formatting"

module TUI
  module Screens
    class Chat
      include Formatting

      MIN_INPUT_HEIGHT = 3
      PRINTABLE_CHAR = /\A[[:print:]]\z/

      ROLE_USER = "user"
      ROLE_ASSISTANT = "assistant"
      ROLE_LABELS = {ROLE_USER => "You", ROLE_ASSISTANT => "Anima"}.freeze

      SCROLL_STEP = 1
      MOUSE_SCROLL_STEP = 2

      TOOL_ICON = "\u{1F527}"
      CLOCK_ICON = "\u{1F552}"
      CHECKMARK = "\u2713"

      ROLE_COLORS = {"user" => "green", "assistant" => "cyan"}.freeze

      # Intentionally duplicated from Session::VIEW_MODES to keep the TUI
      # independent of Rails. Must stay in sync when adding new modes.
      VIEW_MODES = %w[basic verbose debug].freeze

      attr_reader :message_store, :scroll_offset, :session_info, :view_mode, :sessions_list,
        :authentication_required, :token_save_result, :parent_session_id,
        :chat_focused
      attr_accessor :hud_hint

      # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
      # @param message_store [TUI::MessageStore, nil] injectable for testing
      def initialize(cable_client:, message_store: nil)
        @cable_client = cable_client
        @message_store = message_store || MessageStore.new
        @input_buffer = InputBuffer.new
        @flash = Flash.new
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @visible_height = 0
        @max_scroll = 0
        @input_scroll_offset = 0
        @view_mode = "basic"
        @session_info = {id: cable_client.session_id || 0, message_count: 0, active_skills: [], active_workflow: nil, goals: [], children: []}
        @sessions_list = nil
        @parent_session_id = nil
        @authentication_required = false
        @token_save_result = nil
        @chat_focused = false
        @input_history = []
        @history_index = nil
        @saved_input = nil
      end

      def messages
        @message_store.messages
      end

      # @return [String] current input text (delegates to InputBuffer)
      def input
        @input_buffer.text
      end

      # @return [Integer] current cursor position (delegates to InputBuffer)
      def cursor_pos
        @input_buffer.cursor_pos
      end

      def render(frame, area, tui)
        process_incoming_messages

        input_height = calculate_input_height(tui, area.width, area.height)

        chat_area, input_area = tui.split(
          area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(input_height)
          ]
        )

        render_messages(frame, chat_area, tui)
        render_flash(frame, chat_area, tui)

        render_input(frame, input_area, tui)
      end

      # Dispatches keyboard, mouse, and paste events. Supports two focus
      # modes: input mode (default) where arrows navigate the input buffer
      # with bash-style history overflow, and chat-focused mode where arrows
      # scroll the chat pane.
      #
      # Page Up/Down and mouse scroll always control the chat pane
      # regardless of focus mode.
      def handle_event(event)
        return handle_mouse_event(event) if event.mouse?
        return handle_paste_event(event) if event.paste?
        return handle_scroll_key(event) if event.page_up? || event.page_down?

        # Dismiss flash on any keypress (flash auto-expires too)
        @flash.dismiss! if @flash.any?

        return handle_chat_focused_event(event) if @chat_focused

        if event.up?
          return true if @input_buffer.move_up
          return true if @input_buffer.text.empty? && recall_pending_message
          return navigate_history_back
        end

        if event.down?
          return true if @input_buffer.move_down
          return navigate_history_forward
        end

        if event.enter?
          submit_message
          true
        elsif event.backspace?
          reset_history_browsing
          @input_buffer.backspace
          true
        elsif event.delete?
          reset_history_browsing
          @input_buffer.delete
          true
        elsif event.left?
          @input_buffer.move_left
        elsif event.right?
          @input_buffer.move_right
        elsif event.home?
          @input_buffer.move_home
        elsif event.end?
          @input_buffer.move_end
        elsif printable_char?(event) && !@input_buffer.full?
          reset_history_browsing
          @input_buffer.insert(event.code)
        else
          false
        end
      end

      # Creates a new session through the WebSocket protocol.
      # The brain creates the session, switches the channel stream, and sends
      # a session_changed signal followed by (empty) history. The client-side
      # state reset happens when session_changed is received.
      def new_session
        @cable_client.create_session
      end

      # Switches to an existing session through the WebSocket protocol.
      # The brain switches the channel stream and sends a session_changed
      # signal followed by chat history.
      #
      # @param session_id [Integer] target session to switch to
      def switch_session(session_id)
        @cable_client.switch_session(session_id)
      end

      # Sends an explicit view mode switch command to the server.
      # The server broadcasts the mode change and re-transmits the viewport
      # decorated in the new mode to all connected clients.
      #
      # @param mode [String] target view mode ("basic", "verbose", or "debug")
      def switch_view_mode(mode)
        @cable_client.change_view_mode(mode)
      end

      # Sends an interrupt request to the server to stop the current tool chain.
      # Called when Escape is pressed with empty input during active processing.
      #
      # @return [void]
      def interrupt_execution
        @cable_client.interrupt
      end

      # Clears the input buffer. Used when Escape is pressed with non-empty input.
      #
      # @return [void]
      def clear_input
        @input_buffer.clear
      end

      # Clears the authentication_required flag after the App has consumed it.
      # @return [void]
      def clear_authentication_required
        @authentication_required = false
      end

      # Returns and clears the token save result for one-shot consumption by the App.
      # @return [Hash, nil] {success: true} or {success: false, message: "..."}, or nil
      def consume_token_save_result
        result = @token_save_result
        @token_save_result = nil
        result
      end

      def finalize
      end

      def loading?
        @loading
      end

      # Switches focus to the chat pane for keyboard scrolling.
      # @return [void]
      def focus_chat
        @chat_focused = true
      end

      # Returns focus from the chat pane to the input field.
      # @return [void]
      def unfocus_chat
        @chat_focused = false
      end

      private

      # Drains the WebSocket message queue and feeds events to the message store
      def process_incoming_messages
        @cable_client.drain_messages.each do |msg|
          action = msg["action"]
          type = msg["type"]

          case action
          when "session_changed"
            handle_session_changed(msg)
          when "view_mode_changed"
            handle_view_mode_changed(msg)
          when "view_mode"
            @view_mode = msg["view_mode"] if msg["view_mode"]
          when "session_name_updated"
            handle_session_name_updated(msg)
          when "active_skills_updated"
            handle_active_skills_updated(msg)
          when "active_workflow_updated"
            handle_active_workflow_updated(msg)
          when "goals_updated"
            handle_goals_updated(msg)
          when "children_updated"
            handle_children_updated(msg)
          when "sessions_list"
            @sessions_list = msg["sessions"]
          when "user_message_recalled"
            @message_store.remove_by_id(msg["event_id"]) if msg["event_id"]
          when "authentication_required"
            @authentication_required = true
          when "token_saved"
            @authentication_required = false
            @token_save_result = {success: true, warning: msg["warning"]}.compact
          when "token_error"
            @token_save_result = {success: false, message: msg["message"]}
          when "error"
            @flash.error(msg["message"]) if msg["message"]
          else
            case type
            when "bounce_back"
              handle_bounce_back(msg)
            when "connection"
              handle_connection_status(msg)
            when "user_message"
              @message_store.process_event(msg)
              unless action == "update"
                @session_info[:message_count] += 1
                @loading = true
              end
            when "agent_message"
              @message_store.process_event(msg)
              unless action == "update"
                @session_info[:message_count] += 1
                @loading = false
              end
            else # tool_call, tool_response, and other event types
              @message_store.process_event(msg)
            end
          end

          handle_viewport_evictions(msg)
        end
      end

      # Removes messages that left the LLM's context window. Event broadcasts
      # include `evicted_event_ids` when old events are pushed out of the
      # viewport by new ones.
      #
      # @param msg [Hash] incoming WebSocket message
      def handle_viewport_evictions(msg)
        evicted_ids = msg["evicted_event_ids"]
        return unless evicted_ids.is_a?(Array) && evicted_ids.any?

        @message_store.remove_by_ids(evicted_ids)
      end

      # Reacts to connection lifecycle changes from the WebSocket client.
      # Clears stale state when subscription begins so the store is empty
      # before history arrives. Action Cable sends confirm_subscription
      # AFTER transmit calls in the subscribed callback, so clearing on
      # "subscribed" would wipe history that already arrived.
      # Renders flash messages as colored bars inside the chat frame,
      # just below the top border (respecting rounded corners).
      def render_flash(frame, chat_area, tui)
        return unless @flash.any?

        # Inner area: inset by 1 on each side for the chat frame border
        inner = tui.block(borders: [:all]).inner(chat_area)
        @flash.render(frame, inner, tui)
      end

      def handle_connection_status(msg)
        case msg["status"]
        when "subscribing"
          @message_store.clear
          @loading = false
          @session_info[:message_count] = 0
        when "disconnected", "failed"
          @loading = false
        end
      end

      # Handles a Bounce Back event: the server rolled back the user event
      # because LLM delivery failed. Removes the phantom message from the
      # chat, restores the text to the input field, and shows a flash.
      def handle_bounce_back(msg)
        event_id = msg["event_id"]
        content = msg["content"]
        error = msg["error"]

        @message_store.remove_by_id(event_id) if event_id
        @loading = false

        if content
          @input_buffer.clear
          @input_buffer.insert(content)
        end

        @flash.error("Message not delivered: #{error}") if error
      end

      def handle_session_changed(msg)
        new_id = msg["session_id"]
        @cable_client.update_session_id(new_id)
        @message_store.clear
        @view_mode = msg["view_mode"] if msg["view_mode"]
        @session_info = {id: new_id, name: msg["name"], message_count: msg["message_count"] || 0,
                         active_skills: msg["active_skills"] || [], active_workflow: msg["active_workflow"],
                         goals: msg["goals"] || [], children: msg["children"] || []}
        @parent_session_id = msg["parent_session_id"]
        @input_buffer.clear
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @input_scroll_offset = 0
        @chat_focused = false
        reset_history_browsing
      end

      # Updates the session name when a background job generates one.
      # Only applies to the current session.
      def handle_session_name_updated(msg)
        return unless msg["session_id"] == @session_info[:id]

        @session_info[:name] = msg["name"]
      end

      # Updates the active skills list when the analytical brain activates or
      # deactivates skills. Only applies to the current session.
      def handle_active_skills_updated(msg)
        return unless msg["session_id"] == @session_info[:id]

        @session_info[:active_skills] = msg["active_skills"] || []
      end

      # Updates the active workflow when the analytical brain activates or
      # deactivates a workflow. Only applies to the current session.
      def handle_active_workflow_updated(msg)
        return unless msg["session_id"] == @session_info[:id]

        @session_info[:active_workflow] = msg["active_workflow"]
      end

      # Updates the goals list when the analytical brain creates or
      # completes goals. Only applies to the current session.
      def handle_goals_updated(msg)
        return unless msg["session_id"] == @session_info[:id]

        @session_info[:goals] = msg["goals"] || []
      end

      # Updates the children list when a sub-agent is spawned or its
      # processing state changes. Only applies to the current session.
      def handle_children_updated(msg)
        return unless msg["session_id"] == @session_info[:id]

        @session_info[:children] = msg["children"] || []
      end

      # Handles server broadcast of view mode change. Clears the message store
      # in preparation for the re-decorated viewport events that follow.
      def handle_view_mode_changed(msg)
        new_mode = msg["view_mode"]
        return unless new_mode && VIEW_MODES.include?(new_mode)

        @view_mode = new_mode
        @message_store.clear
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
      end

      def render_messages(frame, area, tui)
        lines = build_message_lines(tui)

        if @loading
          lines << tui.line(spans: [
            tui.span(content: "Thinking...", style: tui.style(fg: "yellow", modifiers: [:bold]))
          ])
        end

        if lines.empty?
          lines << tui.line(spans: [
            tui.span(content: "Type a message to start chatting.", style: tui.style(fg: "dark_gray"))
          ])
        end

        inner_width = [area.width - 2, 1].max
        @visible_height = [area.height - 2, 0].max

        base_widget = tui.paragraph(text: lines, wrap: true, style: tui.style(fg: "white"))
        content_height = base_widget.line_count(inner_width)

        @max_scroll = [content_height - @visible_height, 0].max
        @scroll_offset = @max_scroll if @auto_scroll
        @scroll_offset = @scroll_offset.clamp(0, @max_scroll)

        chat_block = {
          title: "Chat",
          borders: [:all],
          border_type: :rounded,
          border_style: @chat_focused ? {fg: "yellow"} : {fg: "cyan"}
        }
        if @chat_focused
          chat_block[:titles] = [
            {content: "\u2191\u2193 scroll  Esc return", position: :bottom, alignment: :center}
          ]
        end

        widget = base_widget.with(scroll: [@scroll_offset, 0], block: tui.block(**chat_block))
        frame.render_widget(widget, area)

        return unless @max_scroll > 0

        scrollbar = tui.scrollbar(
          content_length: @max_scroll,
          position: @scroll_offset,
          orientation: :vertical_right,
          thumb_style: {fg: "cyan"},
          track_symbol: "\u2502",
          track_style: {fg: "dark_gray"}
        )
        frame.render_widget(scrollbar, area)
      end

      def build_message_lines(tui)
        messages.flat_map do |entry|
          case entry[:type]
          when :rendered
            build_rendered_lines(tui, entry)
          when :tool_counter
            build_tool_counter_lines(tui, entry)
          when :message
            build_chat_message_lines(tui, entry)
          end
        end
      end

      # Renders a tool activity counter (e.g. "🔧 Tools: 2/2 ✓").
      # Green when all calls have responses, yellow while in-progress.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param counter [Hash] entry shaped `{type: :tool_counter, calls:, responses:}`
      # @return [Array<RatatuiRuby::Widgets::Line>] counter line + blank separator
      def build_tool_counter_lines(tui, counter)
        calls = counter[:calls]
        responses = counter[:responses]
        complete = calls == responses
        label = "#{TOOL_ICON} Tools: #{calls}/#{responses}#{" #{CHECKMARK}" if complete}"
        color = complete ? "green" : "yellow"
        [
          tui.line(spans: [tui.span(content: label, style: tui.style(fg: color))]),
          tui.line(spans: [tui.span(content: "")])
        ]
      end

      # Renders structured event data from the server. Tool-related roles
      # (tool_call, tool_response, think) are dispatched to per-tool
      # client-side decorators for tool-specific icons, colors, and formatting.
      # Other roles are rendered inline.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param entry [Hash] entry shaped `{type: :rendered, data: Hash}`
      # @return [Array<RatatuiRuby::Widgets::Line>] rendered lines + blank separator
      def build_rendered_lines(tui, entry)
        data = entry[:data]
        role = data["role"].to_s

        lines = case role
        when "user", "assistant"
          render_conversation_entry(tui, data, role)
        when "tool_call", "tool_response", "think"
          Decorators::BaseDecorator.for(data).render(tui)
        when "system"
          render_system_entry(tui, data)
        when "system_prompt"
          render_system_prompt_entry(tui, data)
        else
          [tui.line(spans: [tui.span(content: data["content"].to_s, style: tui.style(fg: "white"))])]
        end

        # Tool calls and their responses are visually one unit — no separator
        # between them. Separator appears after the response completes the pair.
        lines << tui.line(spans: [tui.span(content: "")]) unless entry[:event_type] == "tool_call"
        lines
      end

      # Renders a user or assistant message with optional timestamp and token count.
      # Pending messages are dimmed with a clock icon to indicate they haven't
      # been sent to the LLM yet.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param data [Hash] structured data with "role", "content", and optional
      #   "timestamp", "tokens", "estimated", "status"
      # @param role [String] "user" or "assistant"
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_conversation_entry(tui, data, role)
        pending = data["status"] == "pending"
        color = pending ? "dark_gray" : ROLE_COLORS.fetch(role, "white")
        prefix = ROLE_LABELS.fetch(role, role)
        prefix = "#{CLOCK_ICON} #{prefix}" if pending
        style = tui.style(fg: color)

        meta = []
        meta << "[#{format_ns_timestamp(data["timestamp"])}]" if data["timestamp"]
        meta << format_token_label(data["tokens"], data["estimated"]) if data["tokens"]
        header = meta.empty? ? "#{prefix}:" : "#{meta.join(" ")} #{prefix}:"

        content_lines = data["content"].to_s.split("\n", -1)
        lines = [tui.line(spans: [tui.span(content: "#{header} #{content_lines.first}", style: style)])]
        content_lines.drop(1).each { |line| lines << tui.line(spans: [tui.span(content: line, style: style)]) }
        lines
      end

      # Renders a system message with optional timestamp prefix.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param data [Hash] structured data with "content" and optional "timestamp"
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_system_entry(tui, data)
        ts = data["timestamp"]
        header = ts ? "[#{format_ns_timestamp(ts)}] [system]" : "[system]"
        style = tui.style(fg: "white")

        content_lines = data["content"].to_s.split("\n", -1)
        lines = [tui.line(spans: [tui.span(content: "#{header} #{content_lines.first}", style: style)])]
        content_lines.drop(1).each { |line| lines << tui.line(spans: [tui.span(content: "  #{line}", style: style)]) }
        lines
      end

      # Renders the assembled system prompt block in debug mode.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param data [Hash] structured data with "content", "tokens", "estimated"
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_system_prompt_entry(tui, data)
        token_label = format_token_label(data["tokens"], data["estimated"])
        header = "[SYSTEM] (#{token_label})"
        style = tui.style(fg: "magenta")
        bold_style = tui.style(fg: "magenta", modifiers: [:bold])

        lines = [tui.line(spans: [tui.span(content: header, style: bold_style)])]
        data["content"].to_s.split("\n").each do |line|
          lines << tui.line(spans: [tui.span(content: "  #{line}", style: style)])
        end
        lines
      end

      def build_chat_message_lines(tui, msg)
        role = msg[:role]
        role_style = (role == ROLE_USER) ? tui.style(fg: "green", modifiers: [:bold]) : tui.style(fg: "cyan", modifiers: [:bold])

        label = ROLE_LABELS.fetch(role, role)
        content_lines = msg[:content].to_s.split("\n", -1)

        lines = [tui.line(spans: [
          tui.span(content: "#{label}: ", style: role_style),
          tui.span(content: content_lines.first.to_s)
        ])]
        content_lines.drop(1).each { |text| lines << tui.line(spans: [tui.span(content: text)]) }
        lines << tui.line(spans: [tui.span(content: "")])
      end

      # Dynamically calculates input area height based on wrapped content.
      # Clamped between MIN_INPUT_HEIGHT and 50% of available height.
      def calculate_input_height(_tui, area_width, area_height)
        inner_width = [area_width - 2, 1].max

        content_height = "> #{@input_buffer.text}".split("\n", -1).sum { |pline|
          word_wrap_segments(pline, inner_width).length
        }
        desired = content_height + 2 # top + bottom border

        max_height = [area_height / 2, MIN_INPUT_HEIGHT].max
        desired.clamp(MIN_INPUT_HEIGHT, max_height)
      end

      def render_input(frame, area, tui)
        disabled = !connected?
        styles = input_styles(tui, disabled)

        title = input_title

        inner_width = [area.width - 2, 1].max
        input_visible_height = [area.height - 2, 0].max

        lines = build_input_lines(tui, styles[:text], inner_width)
        input_scroll = calculate_cursor_and_scroll(inner_width, input_visible_height)

        widget = tui.paragraph(
          text: lines,
          scroll: [input_scroll, 0],
          block: tui.block(
            title: title,
            titles: input_bottom_titles(disabled),
            borders: [:all],
            border_type: :rounded,
            border_style: styles[:border]
          )
        )
        frame.render_widget(widget, area)

        return if disabled || @chat_focused

        cursor_x = area.x + 1 + @cursor_visual_col
        cursor_y = area.y + 1 + @cursor_visual_row - input_scroll

        if cursor_y >= area.y + 1 && cursor_y < area.y + area.height - 1
          frame.set_cursor_position(cursor_x, cursor_y)
        end
      end

      def input_styles(tui, disabled)
        border_color = if disabled || @chat_focused
          "dark_gray"
        else
          "green"
        end

        {
          text: disabled ? tui.style(fg: "dark_gray") : tui.style(fg: "white"),
          border: {fg: border_color}
        }
      end

      def input_title
        if !connected?
          "Disconnected"
        else
          "Input"
        end
      end

      def input_bottom_titles(disabled)
        return [] if disabled

        command_hint = @hud_hint ? "C-a → h HUD" : "C-a command"
        [
          {content: command_hint, position: :bottom, alignment: :left},
          {content: "Enter send", position: :bottom, alignment: :center}
        ]
      end

      # Builds input text as pre-wrapped Line objects for the Paragraph widget.
      # Lines are word-wrapped here so the Paragraph renders without its own
      # wrapping, keeping cursor positioning in sync with the displayed text.
      def build_input_lines(tui, text_style, inner_width)
        display = "> #{@input_buffer.text}"
        display.split("\n", -1).flat_map { |pline|
          word_wrap_segments(pline, inner_width).map { |start, len|
            tui.line(spans: [tui.span(content: pline[start, len], style: text_style)])
          }
        }
      end

      # Computes cursor visual position (row, column) and input scroll offset.
      # Uses the full physical line's wrap segments so cursor placement matches
      # the actual rendered word-wrap breaks (not prefix-based approximations).
      # @return [Integer] input scroll offset
      def calculate_cursor_and_scroll(inner_width, visible_height)
        before_display = "> #{@input_buffer.text[0...@input_buffer.cursor_pos]}"
        full_display = "> #{@input_buffer.text}"

        before_physical = before_display.split("\n", -1)
        full_physical = full_display.split("\n", -1)

        cursor_line_idx = before_physical.length - 1

        # Count visual rows for physical lines above the cursor's line
        row = 0
        full_physical[0...cursor_line_idx].each { |pline|
          row += word_wrap_segments(pline, inner_width).length
        }

        # Locate cursor within the full physical line's wrap segments
        full_line = full_physical[cursor_line_idx] || ""
        segments = word_wrap_segments(full_line, inner_width)
        cursor_offset = (before_physical.last || "").length

        col = cursor_offset
        segments.each_with_index do |(start, len), idx|
          if cursor_offset <= start + len
            row += idx
            col = cursor_offset - start
            break
          end
        end

        @cursor_visual_row = [row, 0].max
        @cursor_visual_col = col

        # Snap scroll window: pull up if cursor is above view, push down if below
        return 0 if visible_height <= 0

        if @cursor_visual_row < @input_scroll_offset
          @input_scroll_offset = @cursor_visual_row
        elsif @cursor_visual_row >= @input_scroll_offset + visible_height
          @input_scroll_offset = @cursor_visual_row - visible_height + 1
        end

        @input_scroll_offset
      end

      # Word-wraps a single physical line into segments.
      # Breaks at word boundaries (spaces) when possible, falls back to
      # character-level breaks for words exceeding the width.
      # @param text [String] text to wrap (should not contain newlines)
      # @param width [Integer] maximum visual line width
      # @return [Array<Array(Integer, Integer)>] [start_position, length] pairs
      def word_wrap_segments(text, width)
        return [[0, text.length]] if text.length <= width || width <= 0

        segments = []
        pos = 0

        while pos < text.length
          remaining = text.length - pos
          if remaining <= width
            segments << [pos, remaining]
            break
          end

          break_at = text.rindex(" ", pos + width - 1)
          if break_at && break_at > pos
            segments << [pos, break_at - pos]
            pos = break_at + 1
          else
            segments << [pos, width]
            pos += width
          end
        end

        segments
      end

      def submit_message
        return if @input_buffer.text.strip.empty?
        return unless connected?

        text = @input_buffer.consume
        save_to_history(text)
        reset_history_browsing
        @input_scroll_offset = 0
        @cable_client.speak(text)
      end

      # Recalls the last pending user message for editing. Removes it from
      # the message store, puts its content back in the input buffer, and
      # tells the server to delete the event.
      #
      # @return [Boolean] true if a message was recalled
      def recall_pending_message
        pending = @message_store.last_pending_user_message
        return false unless pending

        @message_store.remove_by_id(pending[:id])
        @input_buffer.clear
        @input_buffer.insert(pending[:content])
        @cable_client.recall_pending(pending[:id])
        true
      end

      # Handles keyboard events when the chat pane has focus.
      # Up/Down scroll the chat; all other keys are ignored.
      #
      # @return [Boolean] true if the event was handled
      def handle_chat_focused_event(event)
        if event.up?
          scroll_up(SCROLL_STEP)
          true
        elsif event.down?
          scroll_down(SCROLL_STEP)
          true
        else
          false
        end
      end

      # Navigates backward through input history (older entries).
      # On first invocation, saves the current input buffer so it can be
      # restored when the user navigates past the newest entry.
      #
      # @return [Boolean] true if a history entry was loaded
      def navigate_history_back
        return false if @input_history.empty?

        if @history_index.nil?
          @saved_input = @input_buffer.text
          @history_index = @input_history.size - 1
        elsif @history_index > 0
          @history_index -= 1
        else
          return false
        end

        load_history_entry(@input_history[@history_index])
        true
      end

      # Navigates forward through input history (newer entries).
      # When navigating past the newest entry, restores the text that was
      # in the input buffer before history browsing started.
      #
      # @return [Boolean] true if navigated, false if not browsing history
      def navigate_history_forward
        return false if @history_index.nil?

        @history_index += 1

        if @history_index >= @input_history.size
          load_history_entry(@saved_input)
          reset_history_browsing
        else
          load_history_entry(@input_history[@history_index])
        end

        true
      end

      # Replaces the input buffer content with a history entry.
      # Cursor is placed at the end of the text.
      #
      # @param text [String] history entry or saved input to load
      # @return [void]
      def load_history_entry(text)
        @input_buffer.clear
        @input_buffer.insert(text)
      end

      # Exits history browsing mode without changing the input buffer.
      # @return [void]
      def reset_history_browsing
        @history_index = nil
        @saved_input = nil
      end

      # Appends a message to input history, skipping consecutive duplicates.
      #
      # @param text [String] submitted message text
      # @return [void]
      def save_to_history(text)
        return if @input_history.last == text

        @input_history << text
      end

      # Dispatches arrow and page keys to {#scroll_up} or {#scroll_down}.
      # @return [true] always redraws after scrolling
      def handle_scroll_key(event)
        if event.up?
          scroll_up(SCROLL_STEP)
        elsif event.down?
          scroll_down(SCROLL_STEP)
        elsif event.page_up?
          scroll_up(@visible_height)
        elsif event.page_down?
          scroll_down(@visible_height)
        end
        true
      end

      # Handles mouse wheel scroll events; ignores other mouse events
      # @return [Boolean] true if the event was a scroll wheel event
      def handle_mouse_event(event)
        if event.scroll_up?
          scroll_up(MOUSE_SCROLL_STEP)
          true
        elsif event.scroll_down?
          scroll_down(MOUSE_SCROLL_STEP)
          true
        else
          false
        end
      end

      # Scrolls the viewport up, clamping at the top.
      # Disables auto-scroll when the user moves away from the bottom.
      # @param lines [Integer] number of lines to scroll
      def scroll_up(lines)
        @scroll_offset = [@scroll_offset - lines, 0].max
        @auto_scroll = @scroll_offset >= @max_scroll
      end

      # Scrolls the viewport down, clamping at max_scroll.
      # Re-enables auto-scroll when the user reaches the bottom.
      # @param lines [Integer] number of lines to scroll
      def scroll_down(lines)
        @scroll_offset = [@scroll_offset + lines, @max_scroll].min
        @auto_scroll = @scroll_offset >= @max_scroll
      end

      # @return [Boolean] true when WebSocket is fully subscribed and ready
      def connected?
        @cable_client.status == :subscribed
      end

      # Inserts pasted clipboard content at cursor position.
      # @param event [RatatuiRuby::Event::Paste] paste event with content
      # @return [Boolean] true if content was inserted, false if buffer full
      def handle_paste_event(event)
        return false if @input_buffer.full?

        reset_history_browsing
        @input_buffer.insert(event.content)
      end

      def printable_char?(event)
        return false if event.modifiers&.include?("ctrl")

        event.code.length == 1 && event.code.match?(PRINTABLE_CHAR)
      end
    end
  end
end
