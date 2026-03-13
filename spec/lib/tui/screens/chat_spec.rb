# frozen_string_literal: true

require "spec_helper"
require "ratatui_ruby"
require "tui/app"

RSpec.describe TUI::Screens::Chat do
  let(:cable_client) do
    instance_double(TUI::CableClient, host: "localhost:42134", session_id: 42, status: :subscribed)
  end
  let(:message_store) { TUI::MessageStore.new }

  subject(:screen) { described_class.new(cable_client: cable_client, message_store: message_store) }

  before do
    allow(cable_client).to receive(:drain_messages).and_return([])
    allow(cable_client).to receive(:speak)
    allow(cable_client).to receive(:create_session)
    allow(cable_client).to receive(:switch_session)
    allow(cable_client).to receive(:list_sessions)
    allow(cable_client).to receive(:update_session_id)
    allow(cable_client).to receive(:change_view_mode)
  end

  # RatatuiRuby::Event uses method_missing for dynamic predicates,
  # so we use plain doubles instead of instance_double
  def key_event(code:, modifiers: nil, **overrides)
    defaults = {
      key?: true, mouse?: false, paste?: false,
      enter?: false, backspace?: false, delete?: false, esc?: false,
      none?: false, ctrl_c?: false, up?: false, down?: false,
      page_up?: false, page_down?: false, left?: false, right?: false,
      home?: false, end?: false
    }
    defaults[:enter?] = true if code == "enter"
    defaults[:backspace?] = true if code == "backspace"
    defaults[:delete?] = true if code == "delete"
    defaults[:esc?] = true if code == "esc"
    defaults[:up?] = true if code == "up"
    defaults[:down?] = true if code == "down"
    defaults[:page_up?] = true if code == "page_up"
    defaults[:page_down?] = true if code == "page_down"
    defaults[:left?] = true if code == "left"
    defaults[:right?] = true if code == "right"
    defaults[:home?] = true if code == "home"
    defaults[:end?] = true if code == "end"
    double("Event", **defaults, code: code, modifiers: modifiers, **overrides)
  end

  def paste_event(content:)
    double("PasteEvent", paste?: true, key?: false, mouse?: false, content: content)
  end

  # Sets input buffer state directly for testing
  def set_input(text, cursor_pos: nil)
    buf = screen.instance_variable_get(:@input_buffer)
    buf.instance_variable_set(:@text, text)
    buf.instance_variable_set(:@cursor_pos, cursor_pos || text.length)
  end

  def mouse_event(kind:, **overrides)
    defaults = {
      key?: false, mouse?: true, enter?: false, backspace?: false, esc?: false,
      none?: false, ctrl_c?: false, up?: false, down?: false,
      page_up?: false, page_down?: false,
      scroll_up?: false, scroll_down?: false, scroll?: false
    }
    defaults[:scroll_up?] = true if kind == "scroll_up"
    defaults[:scroll_down?] = true if kind == "scroll_down"
    defaults[:scroll?] = true if kind.start_with?("scroll")
    double("MouseEvent", **defaults, kind: kind, **overrides)
  end

  describe "#initialize" do
    it "starts with empty messages" do
      expect(screen.messages).to eq([])
    end

    it "starts with empty input" do
      expect(screen.input).to eq("")
    end

    it "starts with cursor at position 0" do
      expect(screen.cursor_pos).to eq(0)
    end

    it "starts not loading" do
      expect(screen.loading?).to be false
    end
  end

  describe "#handle_event" do
    context "character input" do
      it "appends printable characters to input" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        expect(screen.input).to eq("hi")
        expect(screen.cursor_pos).to eq(2)
      end

      it "appends space to input" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: " "))
        screen.handle_event(key_event(code: "i"))
        expect(screen.input).to eq("h i")
      end

      it "accepts uppercase characters (shift modifier)" do
        event = key_event(code: "H", modifiers: ["shift"])
        screen.handle_event(event)
        expect(screen.input).to eq("H")
      end

      it "ignores keys with ctrl modifier" do
        event = key_event(code: "a", modifiers: ["ctrl"])
        expect(screen.handle_event(event)).to be false
      end

      it "stops accepting input at MAX_LENGTH" do
        max = TUI::InputBuffer::MAX_LENGTH
        set_input("a" * max)
        expect(screen.handle_event(key_event(code: "x"))).to be false
        expect(screen.input.length).to eq(max)
      end

      it "returns true for handled character events" do
        expect(screen.handle_event(key_event(code: "a"))).to be true
      end
    end

    context "backspace" do
      it "removes the last character from input" do
        screen.handle_event(key_event(code: "a"))
        screen.handle_event(key_event(code: "b"))
        screen.handle_event(key_event(code: "backspace"))
        expect(screen.input).to eq("a")
      end

      it "handles backspace on empty input" do
        screen.handle_event(key_event(code: "backspace"))
        expect(screen.input).to eq("")
      end

      it "returns true" do
        expect(screen.handle_event(key_event(code: "backspace"))).to be true
      end
    end

    context "enter submits message via WebSocket" do
      it "sends the message via cable_client.speak" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        expect(cable_client).to have_received(:speak).with("hi")
      end

      it "clears input after submit" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))
        expect(screen.input).to eq("")
      end

      it "does not submit empty input" do
        screen.handle_event(key_event(code: "enter"))

        expect(cable_client).not_to have_received(:speak)
      end

      it "does not submit whitespace-only input" do
        screen.handle_event(key_event(code: " "))
        screen.handle_event(key_event(code: " "))
        screen.handle_event(key_event(code: "enter"))

        expect(cable_client).not_to have_received(:speak)
      end

      it "returns true" do
        screen.handle_event(key_event(code: "h"))
        expect(screen.handle_event(key_event(code: "enter"))).to be true
      end
    end

    context "processing incoming WebSocket messages" do
      it "sets loading to true when user_message received from server" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "user_message", "content" => "hi"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be true
      end

      it "sets loading to false when agent_message received" do
        screen.instance_variable_set(:@loading, true)
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "agent_message", "content" => "response"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be false
      end

      it "adds messages to the message store" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "user_message", "content" => "hello"},
          {"type" => "agent_message", "content" => "hi there"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.messages).to contain_exactly(
          a_hash_including(type: :message, role: "user", content: "hello"),
          a_hash_including(type: :message, role: "assistant", content: "hi there")
        )
      end

      it "stores structured decorator data when available" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "user_message", "content" => "hello", "rendered" => {"basic" => {"role" => "user", "content" => "hello"}}},
          {"type" => "agent_message", "content" => "hi", "rendered" => {"basic" => {"role" => "assistant", "content" => "hi"}}}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.messages).to match([
          a_hash_including(type: :rendered, data: {"role" => "user", "content" => "hello"}, event_type: "user_message"),
          a_hash_including(type: :rendered, data: {"role" => "assistant", "content" => "hi"}, event_type: "agent_message")
        ])
      end

      it "tracks tool_call events as tool counter entries" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "user_message", "content" => "hi"},
          {"type" => "tool_call", "content" => "calling bash"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "agent_message", "content" => "done"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.messages).to match([
          a_hash_including(type: :message, role: "user", content: "hi"),
          {type: :tool_counter, calls: 1, responses: 1},
          a_hash_including(type: :message, role: "assistant", content: "done")
        ])
      end

      it "does not increment message_count or set loading on user_message update" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "user_message", "content" => "hi", "id" => 1, "action" => "create"},
          {"type" => "user_message", "content" => "hi", "id" => 1, "action" => "update"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.session_info[:message_count]).to eq(1)
        expect(screen.loading?).to be true
      end

      it "does not change loading state on agent_message update" do
        screen.instance_variable_set(:@loading, true)
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "agent_message", "content" => "done", "id" => 2, "action" => "update"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be true
        expect(screen.session_info[:message_count]).to eq(0)
      end

      it "does not increment message_count for tool events" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "user_message", "content" => "hi"},
          {"type" => "tool_call", "content" => "calling bash"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "tool_call", "content" => "calling web"},
          {"type" => "tool_response", "content" => "ok"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.session_info[:message_count]).to eq(1)
      end

      it "does not store connection status messages as chat messages" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribing"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.messages).to be_empty
      end
    end

    context "connection lifecycle events" do
      it "clears message store on subscribing" do
        message_store.process_event({"type" => "user_message", "content" => "old"})

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribing"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages).to be_empty
      end

      it "resets loading on subscribing" do
        screen.instance_variable_set(:@loading, true)

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribing"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be false
      end

      it "resets message count on subscribing" do
        screen.instance_variable_get(:@session_info)[:message_count] = 5

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribing"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.session_info[:message_count]).to eq(0)
      end

      it "clears loading on disconnected" do
        screen.instance_variable_set(:@loading, true)

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "disconnected"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be false
      end

      it "clears loading on failed" do
        screen.instance_variable_set(:@loading, true)

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "failed"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be false
      end

      it "preserves user input during disconnect" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "disconnected"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.input).to eq("hi")
      end

      it "repopulates from history after reconnect" do
        message_store.process_event({"type" => "user_message", "content" => "old"})

        # Real ordering: subscribing clears store, then history arrives,
        # then subscribed confirms (Action Cable sends confirm_subscription
        # after transmit calls in the subscribed callback).
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribing"},
          {"type" => "user_message", "content" => "restored"},
          {"type" => "agent_message", "content" => "response"},
          {"type" => "connection", "status" => "subscribed"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages).to match([
          a_hash_including(type: :message, role: "user", content: "restored"),
          a_hash_including(type: :message, role: "assistant", content: "response")
        ])
      end

      it "reconstructs tool counters from history on reconnect" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribing"},
          {"type" => "user_message", "content" => "hi"},
          {"type" => "tool_call", "content" => "bash"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "tool_call", "content" => "web"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "agent_message", "content" => "done"},
          {"type" => "connection", "status" => "subscribed"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages).to match([
          a_hash_including(type: :message, role: "user", content: "hi"),
          {type: :tool_counter, calls: 2, responses: 2},
          a_hash_including(type: :message, role: "assistant", content: "done")
        ])
      end
    end

    context "while disconnected" do
      before do
        allow(cable_client).to receive(:status).and_return(:disconnected)
      end

      it "does not submit message when not subscribed" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        expect(cable_client).not_to have_received(:speak)
        expect(screen.input).to eq("hi")
      end

      it "allows typing while disconnected" do
        screen.handle_event(key_event(code: "h"))
        expect(screen.input).to eq("h")
      end
    end

    context "while reconnecting" do
      before do
        allow(cable_client).to receive(:status).and_return(:reconnecting)
      end

      it "does not submit message while reconnecting" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        expect(cable_client).not_to have_received(:speak)
        expect(screen.input).to eq("hi")
      end
    end

    context "while loading" do
      before { screen.instance_variable_set(:@loading, true) }

      it "ignores character input" do
        expect(screen.handle_event(key_event(code: "a"))).to be false
        expect(screen.input).to eq("")
      end

      it "ignores enter" do
        expect(screen.handle_event(key_event(code: "enter"))).to be false
      end

      it "ignores backspace" do
        expect(screen.handle_event(key_event(code: "backspace"))).to be false
      end

      it "ignores delete" do
        expect(screen.handle_event(key_event(code: "delete"))).to be false
      end
    end

    context "scrolling with keyboard" do
      before do
        screen.instance_variable_set(:@visible_height, 10)
        screen.instance_variable_set(:@max_scroll, 20)
        screen.instance_variable_set(:@scroll_offset, 10)
        screen.instance_variable_set(:@auto_scroll, false)
      end

      it "scrolls up one line on arrow up" do
        screen.handle_event(key_event(code: "up"))
        expect(screen.scroll_offset).to eq(9)
      end

      it "scrolls down one line on arrow down" do
        screen.handle_event(key_event(code: "down"))
        expect(screen.scroll_offset).to eq(11)
      end

      it "scrolls up by visible height on page up" do
        screen.handle_event(key_event(code: "page_up"))
        expect(screen.scroll_offset).to eq(0)
      end

      it "scrolls down by visible height on page down" do
        screen.handle_event(key_event(code: "page_down"))
        expect(screen.scroll_offset).to eq(20)
      end

      it "clamps scroll offset to zero" do
        screen.instance_variable_set(:@scroll_offset, 0)
        screen.handle_event(key_event(code: "up"))
        expect(screen.scroll_offset).to eq(0)
      end

      it "clamps scroll offset to max_scroll" do
        screen.instance_variable_set(:@scroll_offset, 20)
        screen.handle_event(key_event(code: "down"))
        expect(screen.scroll_offset).to eq(20)
      end

      it "returns true for scroll key events" do
        expect(screen.handle_event(key_event(code: "up"))).to be true
        expect(screen.handle_event(key_event(code: "down"))).to be true
        expect(screen.handle_event(key_event(code: "page_up"))).to be true
        expect(screen.handle_event(key_event(code: "page_down"))).to be true
      end

      it "works during loading" do
        screen.instance_variable_set(:@loading, true)
        screen.handle_event(key_event(code: "up"))
        expect(screen.scroll_offset).to eq(9)
      end

      it "disables auto-scroll when scrolling up from bottom" do
        screen.instance_variable_set(:@scroll_offset, 20)
        screen.instance_variable_set(:@auto_scroll, true)
        screen.handle_event(key_event(code: "up"))
        expect(screen.instance_variable_get(:@auto_scroll)).to be false
      end

      it "re-enables auto-scroll when scrolling down to bottom" do
        screen.instance_variable_set(:@scroll_offset, 19)
        screen.handle_event(key_event(code: "down"))
        expect(screen.scroll_offset).to eq(20)
        expect(screen.instance_variable_get(:@auto_scroll)).to be true
      end
    end

    context "scrolling with mouse wheel" do
      before do
        screen.instance_variable_set(:@visible_height, 10)
        screen.instance_variable_set(:@max_scroll, 20)
        screen.instance_variable_set(:@scroll_offset, 10)
        screen.instance_variable_set(:@auto_scroll, false)
      end

      it "scrolls up on mouse wheel up" do
        screen.handle_event(mouse_event(kind: "scroll_up"))
        expect(screen.scroll_offset).to eq(10 - TUI::Screens::Chat::MOUSE_SCROLL_STEP)
      end

      it "scrolls down on mouse wheel down" do
        screen.handle_event(mouse_event(kind: "scroll_down"))
        expect(screen.scroll_offset).to eq(10 + TUI::Screens::Chat::MOUSE_SCROLL_STEP)
      end

      it "returns true for scroll wheel events" do
        expect(screen.handle_event(mouse_event(kind: "scroll_up"))).to be true
        expect(screen.handle_event(mouse_event(kind: "scroll_down"))).to be true
      end

      it "returns false for non-scroll mouse events" do
        expect(screen.handle_event(mouse_event(kind: "down"))).to be false
      end

      it "works during loading" do
        screen.instance_variable_set(:@loading, true)
        screen.handle_event(mouse_event(kind: "scroll_up"))
        expect(screen.scroll_offset).to eq(10 - TUI::Screens::Chat::MOUSE_SCROLL_STEP)
      end
    end

    context "cursor movement with arrow keys" do
      before do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "e"))
        screen.handle_event(key_event(code: "l"))
        screen.handle_event(key_event(code: "l"))
        screen.handle_event(key_event(code: "o"))
      end

      it "moves cursor left" do
        screen.handle_event(key_event(code: "left"))
        expect(screen.cursor_pos).to eq(4)
      end

      it "moves cursor right after moving left" do
        screen.handle_event(key_event(code: "left"))
        screen.handle_event(key_event(code: "right"))
        expect(screen.cursor_pos).to eq(5)
      end

      it "returns false when moving left at beginning" do
        set_input("hello", cursor_pos: 0)
        expect(screen.handle_event(key_event(code: "left"))).to be false
      end

      it "returns false when moving right at end" do
        expect(screen.handle_event(key_event(code: "right"))).to be false
      end

      it "inserts characters at cursor position" do
        screen.handle_event(key_event(code: "left"))
        screen.handle_event(key_event(code: "left"))
        screen.handle_event(key_event(code: "X"))
        expect(screen.input).to eq("helXlo")
        expect(screen.cursor_pos).to eq(4)
      end

      it "deletes character before cursor position" do
        screen.handle_event(key_event(code: "left"))
        screen.handle_event(key_event(code: "left"))
        screen.handle_event(key_event(code: "backspace"))
        expect(screen.input).to eq("helo")
        expect(screen.cursor_pos).to eq(2)
      end
    end

    context "home and end keys" do
      before { set_input("hello\nworld", cursor_pos: 8) }

      it "moves cursor to start of current line with home" do
        screen.handle_event(key_event(code: "home"))
        expect(screen.cursor_pos).to eq(6)
      end

      it "moves cursor to end of current line with end" do
        set_input("hello\nworld", cursor_pos: 6)
        screen.handle_event(key_event(code: "end"))
        expect(screen.cursor_pos).to eq(11)
      end

      it "moves to position 0 on first line with home" do
        set_input("hello\nworld", cursor_pos: 3)
        screen.handle_event(key_event(code: "home"))
        expect(screen.cursor_pos).to eq(0)
      end

      it "returns false when already at home position" do
        set_input("hello\nworld", cursor_pos: 6)
        expect(screen.handle_event(key_event(code: "home"))).to be false
      end

      it "returns false when already at end position" do
        set_input("hello\nworld", cursor_pos: 11)
        expect(screen.handle_event(key_event(code: "end"))).to be false
      end
    end

    context "delete key (forward delete)" do
      before { set_input("hello", cursor_pos: 2) }

      it "deletes character at cursor" do
        screen.handle_event(key_event(code: "delete"))
        expect(screen.input).to eq("helo")
        expect(screen.cursor_pos).to eq(2)
      end

      it "does nothing at end of input" do
        set_input("hello", cursor_pos: 5)
        screen.handle_event(key_event(code: "delete"))
        expect(screen.input).to eq("hello")
      end

      it "returns true" do
        expect(screen.handle_event(key_event(code: "delete"))).to be true
      end

      it "deletes newline character" do
        set_input("hello\nworld", cursor_pos: 5)
        screen.handle_event(key_event(code: "delete"))
        expect(screen.input).to eq("helloworld")
      end
    end

    context "clipboard paste" do
      it "inserts pasted text at cursor" do
        set_input("hello ", cursor_pos: 6)
        screen.handle_event(paste_event(content: "world"))
        expect(screen.input).to eq("hello world")
        expect(screen.cursor_pos).to eq(11)
      end

      it "inserts pasted text in the middle" do
        set_input("helo", cursor_pos: 2)
        screen.handle_event(paste_event(content: "ll"))
        expect(screen.input).to eq("helllo")
      end

      it "handles multiline paste" do
        screen.handle_event(paste_event(content: "line1\nline2\nline3"))
        expect(screen.input).to eq("line1\nline2\nline3")
      end

      it "returns true on success" do
        expect(screen.handle_event(paste_event(content: "text"))).to be true
      end

      it "returns false when buffer is full" do
        set_input("x" * TUI::InputBuffer::MAX_LENGTH)
        expect(screen.handle_event(paste_event(content: "more"))).to be false
      end

      it "rejects paste that would exceed MAX_LENGTH" do
        set_input("x" * (TUI::InputBuffer::MAX_LENGTH - 5))
        expect(screen.handle_event(paste_event(content: "too long!"))).to be false
        expect(screen.input.length).to eq(TUI::InputBuffer::MAX_LENGTH - 5)
      end

      it "ignores paste while loading" do
        screen.instance_variable_set(:@loading, true)
        screen.handle_event(paste_event(content: "text"))
        expect(screen.input).to eq("")
      end
    end

    context "backspace deletes newlines" do
      it "joins lines when deleting newline character" do
        set_input("hello\nworld", cursor_pos: 6)
        screen.handle_event(key_event(code: "backspace"))
        expect(screen.input).to eq("helloworld")
        expect(screen.cursor_pos).to eq(5)
      end
    end

    context "unrecognized keys" do
      it "returns false for unknown keys" do
        event = key_event(code: "f5")
        expect(screen.handle_event(event)).to be false
      end
    end
  end

  describe "#new_session" do
    it "sends create_session via WebSocket protocol" do
      screen.new_session
      expect(cable_client).to have_received(:create_session)
    end
  end

  describe "#switch_session" do
    it "sends switch_session via WebSocket protocol" do
      screen.switch_session(99)
      expect(cable_client).to have_received(:switch_session).with(99)
    end
  end

  describe "session_changed protocol message" do
    before do
      message_store.process_event({"type" => "user_message", "content" => "old message"})
      set_input("partial", cursor_pos: 4)
      screen.instance_variable_set(:@loading, true)
      screen.instance_variable_set(:@scroll_offset, 15)
      screen.instance_variable_set(:@auto_scroll, false)
    end

    let(:session_changed_msg) do
      {"action" => "session_changed", "session_id" => 99, "message_count" => 5}
    end

    it "updates cable_client session ID" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)

      expect(cable_client).to have_received(:update_session_id).with(99)
    end

    it "clears messages" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.messages).to eq([])
    end

    it "updates session info" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.session_info).to eq({id: 99, message_count: 5})
    end

    it "clears input and resets cursor" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.input).to eq("")
      expect(screen.cursor_pos).to eq(0)
    end

    it "resets loading state" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.loading?).to be false
    end

    it "resets scroll state" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.scroll_offset).to eq(0)
      expect(screen.instance_variable_get(:@auto_scroll)).to be true
    end
  end

  describe "sessions_list protocol message" do
    it "stores the sessions list" do
      sessions = [{"id" => 1, "message_count" => 3}, {"id" => 2, "message_count" => 0}]
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "sessions_list", "sessions" => sessions}
      ])
      screen.send(:process_incoming_messages)
      expect(screen.instance_variable_get(:@sessions_list)).to eq(sessions)
    end
  end

  describe "session_info tracking" do
    it "starts with cable_client session_id" do
      expect(screen.session_info[:id]).to eq(42)
    end

    it "starts with zero message count" do
      expect(screen.session_info[:message_count]).to eq(0)
    end

    it "increments message count on user_message" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"type" => "user_message", "content" => "hi"}
      ])
      screen.send(:process_incoming_messages)
      expect(screen.session_info[:message_count]).to eq(1)
    end

    it "increments message count on agent_message" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"type" => "agent_message", "content" => "hello"}
      ])
      screen.send(:process_incoming_messages)
      expect(screen.session_info[:message_count]).to eq(1)
    end
  end

  describe "#finalize" do
    it "does not raise" do
      expect { screen.finalize }.not_to raise_error
    end
  end

  describe "view mode" do
    it "starts with basic view_mode" do
      expect(screen.view_mode).to eq("basic")
    end

    describe "#cycle_view_mode" do
      it "sends change_view_mode to cable_client with next mode" do
        screen.cycle_view_mode
        expect(cable_client).to have_received(:change_view_mode).with("verbose")
      end

      it "cycles from verbose to debug" do
        screen.instance_variable_set(:@view_mode, "verbose")
        screen.cycle_view_mode
        expect(cable_client).to have_received(:change_view_mode).with("debug")
      end

      it "cycles from debug to basic" do
        screen.instance_variable_set(:@view_mode, "debug")
        screen.cycle_view_mode
        expect(cable_client).to have_received(:change_view_mode).with("basic")
      end
    end

    describe "view_mode_changed action" do
      it "updates view_mode" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed", "view_mode" => "verbose"}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.view_mode).to eq("verbose")
      end

      it "clears message store" do
        message_store.process_event({"type" => "user_message", "content" => "old"})
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed", "view_mode" => "verbose"}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.messages).to be_empty
      end

      it "resets scroll state" do
        screen.instance_variable_set(:@scroll_offset, 15)
        screen.instance_variable_set(:@auto_scroll, false)
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed", "view_mode" => "verbose"}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.scroll_offset).to eq(0)
        expect(screen.instance_variable_get(:@auto_scroll)).to be true
      end

      it "resets loading state" do
        screen.instance_variable_set(:@loading, true)
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed", "view_mode" => "verbose"}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.loading?).to be false
      end
    end

    describe "view_mode_changed with invalid data" do
      it "ignores nil view_mode and preserves state" do
        message_store.process_event({"type" => "user_message", "content" => "keep me"})
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed", "view_mode" => nil}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.view_mode).to eq("basic")
        expect(screen.messages).not_to be_empty
      end

      it "ignores missing view_mode key and preserves state" do
        message_store.process_event({"type" => "user_message", "content" => "keep me"})
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.view_mode).to eq("basic")
        expect(screen.messages).not_to be_empty
      end

      it "ignores invalid view_mode value and preserves state" do
        message_store.process_event({"type" => "user_message", "content" => "keep me"})
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode_changed", "view_mode" => "hacker_mode"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.view_mode).to eq("basic")
        expect(screen.messages).not_to be_empty
      end
    end

    describe "view_mode action (initial subscription)" do
      it "sets view_mode from server" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "view_mode", "view_mode" => "debug"}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.view_mode).to eq("debug")
      end
    end

    describe "view_mode in session_changed" do
      it "extracts view_mode from session_changed payload" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "session_changed", "session_id" => 99, "message_count" => 0, "view_mode" => "verbose"}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.view_mode).to eq("verbose")
      end
    end
  end

  describe "#word_wrap_segments (private)" do
    def wrap(text, width)
      screen.send(:word_wrap_segments, text, width)
    end

    it "returns single segment for short text" do
      expect(wrap("hello", 10)).to eq([[0, 5]])
    end

    it "returns single segment for text at exact width" do
      expect(wrap("hello", 5)).to eq([[0, 5]])
    end

    it "breaks at word boundary" do
      expect(wrap("hello world", 8)).to eq([[0, 5], [6, 5]])
    end

    it "hard-breaks when a single word exceeds width" do
      expect(wrap("abcdefghij", 4)).to eq([[0, 4], [4, 4], [8, 2]])
    end

    it "handles multiple words with wrapping" do
      expect(wrap("aaa bbb ccc", 8)).to eq([[0, 7], [8, 3]])
    end

    it "breaks before the word that overflows" do
      # "aaaa bbbbcccc" — word "bbbbcccc" (8 chars) doesn't fit after "aaaa " on width 10
      expect(wrap("aaaa bbbbcccc", 10)).to eq([[0, 4], [5, 8]])
    end

    it "handles text with the '>  ' prompt prefix" do
      expect(wrap("> hello world", 10)).to eq([[0, 7], [8, 5]])
    end

    it "returns original for empty text" do
      expect(wrap("", 10)).to eq([[0, 0]])
    end
  end

  describe "cursor visual position with wrapping" do
    # Exercises calculate_cursor_and_scroll via private method
    def cursor_position(inner_width)
      screen.send(:calculate_cursor_and_scroll, inner_width, 10)
      [screen.instance_variable_get(:@cursor_visual_row),
        screen.instance_variable_get(:@cursor_visual_col)]
    end

    it "places cursor correctly for short text" do
      set_input("hello", cursor_pos: 5)
      row, col = cursor_position(80)
      # "> hello" = 7 chars, cursor after "hello" = col 7
      expect(row).to eq(0)
      expect(col).to eq(7)
    end

    it "places cursor at start of wrapped line" do
      # "> aaaa bbbbcccc" with width 10 wraps to:
      #   "> aaaa"  (6 chars)
      #   "bbbbcccc" (8 chars)
      # cursor at pos 5 = on first 'b', col should be 0 on row 1
      set_input("aaaa bbbbcccc", cursor_pos: 5)
      row, col = cursor_position(10)
      expect(row).to eq(1)
      expect(col).to eq(0)
    end

    it "places cursor at end of wrapped line" do
      # cursor at end of "aaaa bbbbcccc" (13 chars), col should be 8 on row 1
      set_input("aaaa bbbbcccc", cursor_pos: 13)
      row, col = cursor_position(10)
      expect(row).to eq(1)
      expect(col).to eq(8)
    end

    it "places cursor correctly with multiline text" do
      set_input("hello\nworld", cursor_pos: 8)
      row, col = cursor_position(80)
      # Line 0: "> hello" (7 chars, 1 visual line)
      # Line 1: "world", cursor at offset 2 within "world" → "wo|rld"
      expect(row).to eq(1)
      expect(col).to eq(2)
    end

    it "places cursor at beginning of input" do
      set_input("hello", cursor_pos: 0)
      row, col = cursor_position(80)
      # "> " prefix → col 2
      expect(row).to eq(0)
      expect(col).to eq(2)
    end
  end

  describe "#format_token_label (private)" do
    it "formats exact token count" do
      expect(screen.send(:format_token_label, 42, false)).to eq("[42 tok]")
    end

    it "prefixes estimated counts with tilde" do
      expect(screen.send(:format_token_label, 28, true)).to eq("[~28 tok]")
    end

    it "returns empty string for nil tokens" do
      expect(screen.send(:format_token_label, nil, false)).to eq("")
    end
  end

  describe "system_prompt message processing" do
    it "stores system_prompt as rendered entry" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {
          "type" => "system_prompt",
          "rendered" => {"debug" => {"role" => "system_prompt", "content" => "You are Anima.", "tokens" => 4, "estimated" => true}}
        }
      ])

      screen.send(:process_incoming_messages)

      expect(screen.messages).to match([
        a_hash_including(type: :rendered, data: {"role" => "system_prompt", "content" => "You are Anima.", "tokens" => 4, "estimated" => true}, event_type: "system_prompt")
      ])
    end
  end
end
