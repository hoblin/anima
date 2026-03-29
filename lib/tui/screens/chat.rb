# frozen_string_literal: true

require_relative "../input_buffer"
require_relative "../flash"
require_relative "../performance_logger"
require_relative "../height_map"
require_relative "../decorators/base_decorator"
require_relative "../decorators/bash_decorator"
require_relative "../decorators/read_decorator"
require_relative "../decorators/edit_decorator"
require_relative "../decorators/write_decorator"
require_relative "../decorators/web_get_decorator"
require_relative "../decorators/think_decorator"
require_relative "../formatting"
require_relative "../braille_spinner"
require "toon"

module TUI
  module Screens
    class Chat
      include Formatting

      MIN_INPUT_HEIGHT = 3
      PRINTABLE_CHAR = /\A[[:print:]]\z/

      ROLE_USER = "user"
      ROLE_ASSISTANT = "assistant"

      SCROLL_STEP = 1
      MOUSE_SCROLL_STEP = 2

      TOOL_ICON = "\u{1F527}"
      CHECKMARK = "\u2713"

      # Viewport virtualization tuning
      VIEWPORT_BACK_BUFFER = 3    # entries before scroll target for upward scroll margin
      VIEWPORT_OVERFLOW_MULTIPLIER = 2 # build this many viewports worth of lines
      VIEWPORT_BOTTOM_THRESHOLD = 10   # entries from end before we include all trailing

      # Background-highlighted styles for conversation roles.
      # Dark tinted backgrounds make user/assistant messages easy to scan.
      # 22 = dark green (#005f00), 17 = dark navy (#00005f) in 256-color.
      ROLE_STYLES = {
        "user" => {fg: "white", bg: 22, modifiers: [:bold]},
        "assistant" => {fg: "white", bg: 17, modifiers: [:bold]}
      }.freeze

      # Intentionally duplicated from Session::VIEW_MODES to keep the TUI
      # independent of Rails. Must stay in sync when adding new modes.
      VIEW_MODES = %w[basic verbose debug].freeze

      attr_reader :message_store, :scroll_offset, :session_info, :view_mode, :sessions_list,
        :authentication_required, :token_save_result, :parent_session_id,
        :chat_focused, :session_state, :spinner
      attr_accessor :hud_hint

      # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
      # @param message_store [TUI::MessageStore, nil] injectable for testing
      # @param perf_logger [TUI::PerformanceLogger, nil] optional performance logger
      def initialize(cable_client:, message_store: nil, perf_logger: nil)
        @cable_client = cable_client
        @message_store = message_store || MessageStore.new
        @perf_logger = perf_logger || PerformanceLogger.new(enabled: false)
        @input_buffer = InputBuffer.new
        @flash = Flash.new
        @session_state = "idle"
        @spinner = BrailleSpinner.new
        @scroll_offset = 0
        @auto_scroll = true
        @visible_height = 0
        @max_scroll = 0
        @input_scroll_offset = 0
        @view_mode = "basic"
        @session_info = {id: cable_client.session_id || 0, agent_name: "Anima", message_count: 0, active_skills: [], active_workflow: nil, goals: [], children: []}
        @sessions_list = nil
        @parent_session_id = nil
        @authentication_required = false
        @token_save_result = nil
        @chat_focused = false
        @input_history = []
        @history_index = nil
        @saved_input = nil
        # Viewport virtualization: only renders messages visible in the scroll
        # window. Heights are estimated for all entries (cheap string math),
        # but Line objects are only built for the visible range + buffer.
        @height_map = HeightMap.new
        @height_map_version = -1
        @height_map_width = nil
        @height_map_loading = nil
        @viewport = viewport_cache_empty
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

      # Whether the session is actively processing (any state other than idle).
      # Used by the App's HUD and scroll calculations.
      #
      # @return [Boolean]
      def loading?
        @session_state != "idle"
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

      # Short label describing the current session state for HUD display.
      #
      # @return [String]
      def spinner_label
        case @session_state
        when "llm_generating" then "Thinking..."
        when "tool_executing" then "Executing..."
        when "interrupting" then "Stopping..."
        else "Working..."
        end
      end

      # Color name for the spinner and HUD label based on session state.
      # Follows the two-channel design: color = status (green = working,
      # red = stopping). The braille animation pattern communicates type.
      #
      # @return [String]
      def spinner_color
        case @session_state
        when "llm_generating", "tool_executing" then "green"
        when "interrupting" then "red"
        else "dark_gray"
        end
      end

      private

      # Drains the WebSocket message queue and feeds events to the message store
      def process_incoming_messages
        @cable_client.drain_messages.each do |msg|
          action = msg["action"]
          type = msg["type"]

          case action
          when "session_state"
            handle_session_state(msg)
          when "child_state"
            handle_child_state(msg)
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
          when "pending_message_created"
            @message_store.add_pending(msg["pending_message_id"], msg["content"]) if msg["pending_message_id"]
          when "pending_message_removed"
            @message_store.remove_pending(msg["pending_message_id"]) if msg["pending_message_id"]
          when "authentication_required"
            @authentication_required = true
          when "token_saved"
            @authentication_required = false
            @token_save_result = {success: true, warning: msg["warning"]}.compact
          when "token_error"
            @token_save_result = {success: false, message: msg["message"]}
          when "interrupt_acknowledged"
            @flash.info("Interrupting...")
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
              end
            when "agent_message"
              @message_store.process_event(msg)
              unless action == "update"
                @session_info[:message_count] += 1
              end
            else # tool_call, tool_response, and other event types
              @message_store.process_event(msg)
            end
          end

          handle_viewport_evictions(msg)
        end
      end

      # Removes messages that left the LLM's context window. Broadcasts
      # include `evicted_message_ids` when old messages are pushed out of the
      # viewport by new ones.
      #
      # @param msg [Hash] incoming WebSocket message
      def handle_viewport_evictions(msg)
        evicted_ids = msg["evicted_message_ids"]
        return unless evicted_ids.is_a?(Array) && evicted_ids.any?

        @message_store.remove_by_ids(evicted_ids)
      end

      # Renders flash messages as colored bars inside the chat frame,
      # just below the top border (respecting rounded corners).
      def render_flash(frame, chat_area, tui)
        return unless @flash.any?

        # Inner area: inset by 1 on each side for the chat frame border
        inner = tui.block(borders: [:all]).inner(chat_area)
        @flash.render(frame, inner, tui)
      end

      # Reacts to connection lifecycle changes from the WebSocket client.
      # Clears stale state when subscription begins so the store is empty
      # before history arrives. Action Cable sends confirm_subscription
      # AFTER transmit calls in the subscribed callback, so clearing on
      # "subscribed" would wipe history that already arrived.
      def handle_connection_status(msg)
        case msg["status"]
        when "subscribing"
          @message_store.clear
          update_session_state("idle")
          @session_info[:message_count] = 0
        when "disconnected", "failed"
          update_session_state("idle")
        end
      end

      # Handles a Bounce Back: the server rolled back the user message
      # because LLM delivery failed. Removes the phantom message from the
      # chat, restores the text to the input field, and shows a flash.
      def handle_bounce_back(msg)
        message_id = msg["message_id"]
        content = msg["content"]
        error = msg["error"]

        @message_store.remove_by_id(message_id) if message_id
        update_session_state("idle")

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
        @session_info = {id: new_id, name: msg["name"], agent_name: msg["agent_name"] || "Anima",
                         message_count: msg["message_count"] || 0,
                         active_skills: msg["active_skills"] || [], active_workflow: msg["active_workflow"],
                         goals: msg["goals"] || [], children: msg["children"] || []}
        @parent_session_id = msg["parent_session_id"]
        @input_buffer.clear
        update_session_state("idle")
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

      # Handles explicit session state transitions from the server.
      # Drives the braille spinner animation. Only processes broadcasts
      # matching the current session.
      #
      # @param msg [Hash] ActionCable payload with "session_id" and "state" keys
      # @return [void]
      def handle_session_state(msg)
        return unless msg["session_id"] == @session_info[:id]

        update_session_state(msg["state"])
      end

      # Handles a child session's state change broadcast from the
      # parent stream. Merges the state into the children list so
      # HUD icons update without a full children_updated query.
      #
      # @param msg [Hash] ActionCable payload with "child_id" and "state" keys
      # @return [void]
      def handle_child_state(msg)
        child_id = msg["child_id"]
        return unless child_id

        child = @session_info[:children]&.find { |c| c["id"] == child_id }
        child["session_state"] = msg["state"] if child
      end

      # Updates the session state and synchronizes the spinner.
      #
      # @param state [String] one of "idle", "llm_generating",
      #   "tool_executing", "interrupting"
      def update_session_state(state)
        @session_state = state
        @spinner.state = state
      end

      # Builds the animated spinner line for the current session state.
      # The braille character communicates state through its animation
      # pattern; a short label follows for clarity.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [RatatuiRuby::Widgets::Line]
      def spinner_line(tui)
        char = @spinner.tick || "\u2800"
        label = spinner_label
        color = spinner_color

        tui.line(spans: [
          tui.span(content: "#{char} ", style: tui.style(fg: color, modifiers: [:bold])),
          tui.span(content: label, style: tui.style(fg: color))
        ])
      end

      # Handles server broadcast of view mode change. Clears the message store
      # in preparation for the re-decorated viewport events that follow.
      def handle_view_mode_changed(msg)
        new_mode = msg["view_mode"]
        return unless new_mode && VIEW_MODES.include?(new_mode)

        @view_mode = new_mode
        @message_store.clear
        update_session_state("idle")
        @scroll_offset = 0
        @auto_scroll = true
      end

      # Renders chat messages using viewport virtualization.
      # Only builds Line objects for entries visible in the scroll window,
      # keeping render cost constant regardless of conversation length.
      #
      # Uses overflow-based viewport building: starts from the estimated
      # scroll position and builds entries forward until enough lines
      # accumulate to fill the viewport. Real line counts (not estimates)
      # determine when to stop, so the buffer naturally adapts to entry
      # sizes — no fixed entry-count buffer needed.
      def render_messages(frame, area, tui)
        inner_width = [area.width - 2, 1].max
        @visible_height = [area.height - 2, 0].max
        entries = messages
        version = @message_store.version

        if entries.empty?
          render_empty_or_loading(frame, area, tui)
          return
        end

        # Phase 1: Height estimation — O(n) string math, cached by version+width.
        # Needed for total_height / scrollbar / scroll-offset-to-entry mapping.
        @perf_logger.measure(:estimate_heights) { update_height_map(entries, inner_width, version) }

        # Phase 2: Preliminary scroll offset for visible_range lookup.
        # Don't clamp here — Phase 5.5 sets the authoritative @max_scroll
        # from actual viewport height. Clamping here would cap scroll_offset
        # to the (under)estimated total, making the bottom unreachable.
        if @auto_scroll
          @scroll_offset = [@height_map.total_height - @visible_height, 0].max
        end

        # Phase 3: Find approximate first visible entry
        first_vis, = @height_map.visible_range(@scroll_offset, @visible_height)

        # Phase 4: Build Line objects using overflow — stops when viewport is full
        lines = @perf_logger.measure(:build_lines) {
          cached_viewport_lines(tui, entries, version, first_vis)
        }

        # Phase 5: Paragraph widget + wrapped line count
        base_widget = @perf_logger.measure(:paragraph) {
          tui.paragraph(text: lines, wrap: true, style: tui.style(fg: "white"))
        }
        wrapped_height = @perf_logger.measure(:line_count) {
          cached_viewport_line_count(base_widget, inner_width, version)
        }

        # Phase 5.5: Correct scroll state using actual viewport height.
        # Replace the estimated viewport portion with the real wrapped_height.
        vp_first = @viewport[:first]
        vp_last = @viewport[:last]
        est_before = @height_map.cumulative_height(vp_first)
        est_after = @height_map.total_height - @height_map.cumulative_height(vp_last + 1)
        corrected_total = est_before + wrapped_height + est_after

        @max_scroll = [corrected_total - @visible_height, 0].max
        @scroll_offset = @max_scroll if @auto_scroll
        @scroll_offset = @scroll_offset.clamp(0, @max_scroll)

        # Phase 6: Map global scroll_offset into the viewport paragraph.
        # est_before cancels between scroll_offset and max_scroll, so
        # estimation errors don't create a dead zone at the bottom —
        # they shift to the top (oldest messages) where they're harmless.
        max_adjusted = [wrapped_height - @visible_height, 0].max
        adjusted_scroll = (@scroll_offset - est_before).clamp(0, max_adjusted)

        widget = @perf_logger.measure(:widget_with) {
          base_widget.with(scroll: [adjusted_scroll, 0], block: tui.block(**chat_block_config))
        }
        @perf_logger.measure(:render_widget) { frame.render_widget(widget, area) }

        if @max_scroll > 0
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

        # Spinner overlay: rendered on top of the last line inside the
        # chat border, rebuilt every frame. Independent of the viewport
        # cache — the braille animation advances without cache invalidation.
        render_spinner_overlay(frame, area, tui) if loading?
      end

      # Renders the spinner as a 1-line overlay at the bottom of the chat
      # pane, inside the border. Painted on top of whatever the messages
      # paragraph rendered there — same pattern as the token setup popup.
      def render_spinner_overlay(frame, area, tui)
        inner = tui.block(**chat_block_config).inner(area)
        return if inner.height < 1

        spinner_rect = tui.rect(
          x: inner.x,
          y: inner.y + inner.height - 1,
          width: inner.width,
          height: 1
        )
        frame.render_widget(tui.clear, spinner_rect)
        widget = tui.paragraph(text: [spinner_line(tui)])
        frame.render_widget(widget, spinner_rect)
      end

      # Renders the empty or loading state placeholder when no messages exist.
      # Resets scroll state since there is no scrollable content.
      #
      # @param frame [RatatuiRuby::Frame] current render frame
      # @param area [RatatuiRuby::Rect] available area for the chat pane
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [void]
      def render_empty_or_loading(frame, area, tui)
        lines = if loading?
          [spinner_line(tui)]
        else
          [tui.line(spans: [
            tui.span(content: "Type a message to start chatting.", style: tui.style(fg: "dark_gray"))
          ])]
        end

        widget = tui.paragraph(text: lines, wrap: true, style: tui.style(fg: "white"))
          .with(scroll: [0, 0], block: tui.block(**chat_block_config))
        frame.render_widget(widget, area)
        @max_scroll = 0
        @scroll_offset = 0
      end

      # Re-estimates entry heights when content or width changes.
      # Height estimation is O(n) string-length math — orders of
      # magnitude cheaper than building Line/Span objects. Skips
      # re-estimation when version and width are unchanged.
      #
      # @param entries [Array<Hash>] message store entries
      # @param width [Integer] available terminal width
      # @param version [Integer] message store version counter
      # @return [void]
      def update_height_map(entries, width, version)
        return if version == @height_map_version && width == @height_map_width

        @height_map.update(entries, width) { |entry, avail_width| estimate_entry_height(entry, avail_width) }
        @height_map_version = version
        @height_map_width = width
      end

      # Returns cached viewport lines, rebuilding only when content
      # changes or scroll moves outside the cached range. Uses overflow
      # building: starts from a back-buffer before the visible entry and
      # builds forward until the pre-wrap line count exceeds 2x the
      # viewport height. Real line counts determine the buffer size, so
      # it naturally adapts to entry sizes.
      def cached_viewport_lines(tui, entries, version, first_visible_est)
        vp = @viewport
        vp_first = vp[:first]

        # Cache hit: content unchanged and scroll target within the built range
        if version == vp[:version] &&
            vp_first && first_visible_est >= vp_first && first_visible_est <= vp[:last]
          return vp[:lines]
        end

        entry_count = entries.size

        # Start a few entries before the scroll target for upward buffer
        buf_first = [first_visible_est - VIEWPORT_BACK_BUFFER, 0].max

        # Build forward until we've accumulated enough lines to fill the
        # viewport with margin. Pre-wrap count is a lower bound on visual
        # height (wrapping only adds lines), so 2x guarantees coverage.
        target = @visible_height * VIEWPORT_OVERFLOW_MULTIPLIER
        lines = []
        pre_wrap_count = 0
        buf_last = buf_first

        (buf_first...entry_count).each do |idx|
          entry_lines = build_entry_lines(tui, entries[idx])
          lines.concat(entry_lines)
          pre_wrap_count += entry_lines.size
          buf_last = idx
          # Stop early only when we have enough lines AND are far from
          # the bottom. Near the bottom, always include trailing entries
          # so the viewport covers the actual end of content — otherwise
          # the last entries become unreachable.
          break if pre_wrap_count >= target && entry_count - idx > VIEWPORT_BOTTOM_THRESHOLD
        end

        @perf_logger.info(
          "viewport MISS range=#{buf_first}..#{buf_last} " \
          "of=#{entry_count} lines=#{lines.size}"
        )

        @viewport = {
          version: version, width: nil,
          first: buf_first, last: buf_last,
          lines: lines, wrapped_height: nil
        }
        lines
      end

      # Returns cached wrapped line count for the viewport paragraph.
      # Avoids the expensive FFI line_count call when the viewport
      # content and width haven't changed.
      def cached_viewport_line_count(widget, width, version)
        vp = @viewport
        cached_height = vp[:wrapped_height]
        if cached_height && version == vp[:version] && width == vp[:width]
          return cached_height
        end

        height = widget.line_count(width)
        @viewport[:width] = width
        @viewport[:wrapped_height] = height
        @perf_logger.info("viewport_lc MISS width=#{width} wrapped=#{height}")
        height
      end

      # Builds Line objects for a single message store entry.
      # Dispatches by entry type to the appropriate line builder.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @param entry [Hash] message store entry
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def build_entry_lines(tui, entry)
        case entry[:type]
        when :rendered then build_rendered_lines(tui, entry)
        when :tool_counter then build_tool_counter_lines(tui, entry)
        when :message then build_chat_message_lines(tui, entry)
        else []
        end
      end

      # Estimates visual (wrapped) line count for a message store entry.
      # Used only for scroll mapping (total_height, scrollbar) — the
      # actual viewport uses real line counts from overflow building.
      #
      # @param entry [Hash] message store entry
      # @param width [Integer] available terminal width
      # @return [Integer] estimated visual lines (minimum 1)
      def estimate_entry_height(entry, width)
        effective_width = [width, 1].max

        case entry[:type]
        when :tool_counter
          2 # counter line + blank separator
        when :rendered
          data = entry[:data]
          text = [data["content"], data["input"]].compact.map(&:to_s).reject(&:empty?).join("\n")
          lines = estimate_text_height(text, effective_width)
          lines += 1 # header/label line
          lines += 1 unless entry[:message_type] == "tool_call" # separator
          lines
        when :message
          lines = estimate_text_height(entry[:content].to_s, effective_width)
          lines + 1 # separator
        else
          1
        end
      end

      # Estimates visual line count for multi-line text after word-wrapping.
      #
      # @param text [String] content text with embedded newlines
      # @param width [Integer] available width
      # @return [Integer] estimated visual line count (minimum 1)
      def estimate_text_height(text, width)
        return 1 if text.empty?

        text.split("\n", -1).sum { |line|
          [(line.length.to_f / width).ceil, 1].max
        }
      end

      VIEWPORT_CACHE_EMPTY = {
        version: -1, loading: nil, width: nil,
        first: nil, last: nil, lines: nil, wrapped_height: nil
      }.freeze

      def viewport_cache_empty
        VIEWPORT_CACHE_EMPTY.dup
      end

      # Builds the shared chat pane block config with focus-aware styling.
      # @return [Hash] block configuration for tui.block
      def chat_block_config
        config = {
          title: "Chat",
          borders: [:all],
          border_type: :rounded,
          border_style: @chat_focused ? {fg: "yellow"} : {fg: "cyan"}
        }
        if @chat_focused
          config[:titles] = [
            {content: "\u2191\u2193 scroll  Esc return", position: :bottom, alignment: :center}
          ]
        end
        config
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
        lines << tui.line(spans: [tui.span(content: "")]) unless entry[:message_type] == "tool_call"
        lines
      end

      # Renders a user or assistant message with optional timestamp and token count.
      # Pending messages are dimmed to indicate they haven't been sent to the
      # LLM yet.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param data [Hash] structured data with "role", "content", and optional
      # Display label for a conversation role. Uses the agent name from
      # Settings (delivered via session_changed) for the assistant role.
      #
      # @param role [String] "user" or "assistant"
      # @return [String] display label
      def role_label(role)
        return "You" if role == ROLE_USER
        return @session_info[:agent_name] || "Anima" if role == ROLE_ASSISTANT

        role
      end

      #   "timestamp", "tokens", "estimated", "status"
      # @param role [String] "user" or "assistant"
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_conversation_entry(tui, data, role)
        pending = data["status"] == "pending"
        label = role_label(role)

        if pending
          style = tui.style(fg: "gray")
        else
          role_cfg = ROLE_STYLES.fetch(role, {fg: "white"})
          style = tui.style(**role_cfg)
        end

        tokens = data["tokens"]
        content_lines = data["content"].to_s.split("\n", -1)
        first_content = content_lines.first
        ts = data["timestamp"]
        ts_prefix = ts ? "[#{format_ns_timestamp(ts)}] " : ""

        first_spans = if tokens && !pending
          tok_style = {fg: token_count_color(tokens)}
          role_bg = ROLE_STYLES.dig(role, :bg)
          tok_style[:bg] = role_bg if role_bg
          [
            tui.span(content: ts_prefix, style: style),
            tui.span(content: "#{format_token_label(tokens, data["estimated"])} ", style: tui.style(**tok_style)),
            tui.span(content: "#{label}: #{first_content}", style: style)
          ]
        else
          header = ts_prefix.empty? ? "#{label}:" : "#{ts_prefix}#{label}:"
          [tui.span(content: "#{header} #{first_content}", style: style)]
        end

        lines = [tui.line(spans: first_spans)]
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

      # Renders the assembled system prompt and tool schemas in debug mode.
      # Tool schemas are converted to TOON format for readability.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param data [Hash] structured data with "content", "tokens", "estimated",
      #   and optionally "tools" (Array<Hash> of tool schemas)
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_system_prompt_entry(tui, data)
        tokens = data["tokens"]
        bold_style = tui.style(fg: "magenta", modifiers: [:bold])
        style = tui.style(fg: "magenta")
        tool_style = tui.style(fg: "cyan")

        header_spans = [tui.span(content: "[SYSTEM] ", style: bold_style)]
        if tokens
          tok_label = format_token_label(tokens, data["estimated"])
          header_spans << tui.span(content: "(#{tok_label})", style: tui.style(fg: token_count_color(tokens)))
        end

        lines = [tui.line(spans: header_spans)]
        data["content"].to_s.split("\n").each do |line|
          lines << tui.line(spans: [tui.span(content: "  #{line}", style: style)])
        end

        if data["tools"].is_a?(Array) && data["tools"].any?
          lines << tui.line(spans: [tui.span(content: "", style: style)])
          lines << tui.line(spans: [tui.span(content: "\u00a0\u00a0## Tools (#{data["tools"].size})", style: bold_style)])
          tools_toon(data).split("\n").each do |line|
            lines << tui.line(spans: [tui.span(content: line, style: tool_style)])
          end
        end

        lines
      end

      # Converts tool schemas to TOON format for display. Caches the result
      # on the data hash so the conversion runs once per broadcast, not per
      # frame. Uses non-breaking spaces for indentation because ratatui's
      # Paragraph widget with wrap:true trims regular leading spaces.
      # @param data [Hash] entry data containing "tools" array
      # @return [String] TOON-formatted tool schemas
      def tools_toon(data)
        data["tools_toon"] ||= Toon.encode(data["tools"])
          .gsub(/^( +)/) { "\u00a0" * _1.length }
      end

      def build_chat_message_lines(tui, msg)
        role = msg[:role]
        role_cfg = ROLE_STYLES.fetch(role, {fg: "white"})
        role_style = tui.style(**role_cfg)

        label = role_label(role)
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
      # tells the server to delete the {PendingMessage}.
      #
      # @return [Boolean] true if a message was recalled
      def recall_pending_message
        pending = @message_store.last_pending_user_message
        return false unless pending

        @message_store.remove_pending(pending[:pending_message_id])
        @input_buffer.clear
        @input_buffer.insert(pending[:content])
        @cable_client.recall_pending(pending[:pending_message_id])
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
        elsif event.home?
          scroll_up(@max_scroll)
          true
        elsif event.end?
          scroll_down(@max_scroll)
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
