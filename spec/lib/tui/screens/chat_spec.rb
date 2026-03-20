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

      it "removes entry on user_message_recalled" do
        message_store.process_event({"type" => "user_message", "id" => 42,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "pending", "status" => "pending"}}})

        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "user_message_recalled", "event_id" => 42}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages).to be_empty
      end

      it "removes evicted events from message store" do
        message_store.process_event({"type" => "user_message", "id" => 1,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "old msg"}}})
        message_store.process_event({"type" => "agent_message", "id" => 2,
                                     "rendered" => {"basic" => {"role" => "assistant", "content" => "old reply"}}})
        message_store.process_event({"type" => "user_message", "id" => 3,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "recent"}}})

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "agent_message", "id" => 4, "action" => "create",
           "rendered" => {"basic" => {"role" => "assistant", "content" => "new reply"}},
           "evicted_event_ids" => [1, 2]}
        ])
        screen.send(:process_incoming_messages)

        ids = screen.messages.map { |m| m[:id] }
        expect(ids).to eq([3, 4])
      end

      it "ignores evicted_event_ids when not an array" do
        message_store.process_event({"type" => "user_message", "id" => 1,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "agent_message", "id" => 2, "action" => "create",
           "rendered" => {"basic" => {"role" => "assistant", "content" => "reply"}},
           "evicted_event_ids" => "not-an-array"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages.size).to eq(2)
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

    context "while loading (non-blocking input)" do
      before { screen.instance_variable_set(:@loading, true) }

      it "accepts character input" do
        screen.handle_event(key_event(code: "a"))
        expect(screen.input).to eq("a")
      end

      it "accepts enter to submit pending message" do
        allow(cable_client).to receive(:speak)
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))
        expect(cable_client).to have_received(:speak).with("hi")
      end

      it "accepts backspace" do
        screen.handle_event(key_event(code: "a"))
        screen.handle_event(key_event(code: "backspace"))
        expect(screen.input).to eq("")
      end

      it "accepts paste" do
        screen.handle_event(paste_event(content: "hello"))
        expect(screen.input).to eq("hello")
      end
    end

    context "scrolling with keyboard" do
      before do
        screen.instance_variable_set(:@visible_height, 10)
        screen.instance_variable_set(:@max_scroll, 20)
        screen.instance_variable_set(:@scroll_offset, 10)
        screen.instance_variable_set(:@auto_scroll, false)
      end

      it "does not scroll on arrow up in input mode" do
        screen.handle_event(key_event(code: "up"))
        expect(screen.scroll_offset).to eq(10)
      end

      it "does not scroll on arrow down in input mode" do
        screen.handle_event(key_event(code: "down"))
        expect(screen.scroll_offset).to eq(10)
      end

      it "scrolls up by visible height on page up" do
        screen.handle_event(key_event(code: "page_up"))
        expect(screen.scroll_offset).to eq(0)
      end

      it "scrolls down by visible height on page down" do
        screen.handle_event(key_event(code: "page_down"))
        expect(screen.scroll_offset).to eq(20)
      end

      it "clamps scroll offset to zero on page up" do
        screen.instance_variable_set(:@scroll_offset, 3)
        screen.handle_event(key_event(code: "page_up"))
        expect(screen.scroll_offset).to eq(0)
      end

      it "clamps scroll offset to max_scroll on page down" do
        screen.instance_variable_set(:@scroll_offset, 18)
        screen.handle_event(key_event(code: "page_down"))
        expect(screen.scroll_offset).to eq(20)
      end

      it "returns true for page up/down events" do
        expect(screen.handle_event(key_event(code: "page_up"))).to be true
        expect(screen.handle_event(key_event(code: "page_down"))).to be true
      end

      it "page up/down works during loading" do
        screen.instance_variable_set(:@loading, true)
        screen.handle_event(key_event(code: "page_up"))
        expect(screen.scroll_offset).to eq(0)
      end

      it "disables auto-scroll when scrolling up from bottom with page up" do
        screen.instance_variable_set(:@scroll_offset, 20)
        screen.instance_variable_set(:@auto_scroll, true)
        screen.handle_event(key_event(code: "page_up"))
        expect(screen.instance_variable_get(:@auto_scroll)).to be false
      end

      it "re-enables auto-scroll when scrolling down to bottom with page down" do
        screen.instance_variable_set(:@scroll_offset, 15)
        screen.handle_event(key_event(code: "page_down"))
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

    context "arrow-up recall of pending messages" do
      before do
        allow(cable_client).to receive(:recall_pending)
      end

      it "recalls last pending message into input buffer" do
        message_store.process_event({"type" => "user_message", "id" => 42,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "pending msg", "status" => "pending"}}})

        expect(screen.handle_event(key_event(code: "up"))).to be true
        expect(screen.input).to eq("pending msg")
        expect(cable_client).to have_received(:recall_pending).with(42)
      end

      it "removes recalled message from message store" do
        message_store.process_event({"type" => "user_message", "id" => 42,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "pending msg", "status" => "pending"}}})

        screen.handle_event(key_event(code: "up"))
        expect(screen.messages).to be_empty
      end

      it "returns false when no pending message and no history" do
        expect(screen.handle_event(key_event(code: "up"))).to be false
      end

      it "does not scroll when input is not empty and no pending message" do
        screen.instance_variable_set(:@visible_height, 10)
        screen.instance_variable_set(:@max_scroll, 20)
        screen.instance_variable_set(:@scroll_offset, 10)

        set_input("some text")
        screen.handle_event(key_event(code: "up"))
        expect(screen.scroll_offset).to eq(10)
        expect(screen.input).to eq("some text")
      end
    end

    context "chat focused mode" do
      before do
        screen.instance_variable_set(:@visible_height, 10)
        screen.instance_variable_set(:@max_scroll, 20)
        screen.instance_variable_set(:@scroll_offset, 10)
        screen.instance_variable_set(:@auto_scroll, false)
        screen.focus_chat
      end

      it "scrolls up on arrow up" do
        screen.handle_event(key_event(code: "up"))
        expect(screen.scroll_offset).to eq(9)
      end

      it "scrolls down on arrow down" do
        screen.handle_event(key_event(code: "down"))
        expect(screen.scroll_offset).to eq(11)
      end

      it "returns true for arrow keys" do
        expect(screen.handle_event(key_event(code: "up"))).to be true
        expect(screen.handle_event(key_event(code: "down"))).to be true
      end

      it "returns false for other keys" do
        expect(screen.handle_event(key_event(code: "a"))).to be false
      end

      it "does not insert characters into input buffer" do
        screen.handle_event(key_event(code: "a"))
        expect(screen.input).to eq("")
      end

      it "page up/down still scrolls chat" do
        screen.handle_event(key_event(code: "page_up"))
        expect(screen.scroll_offset).to eq(0)
      end

      it "mouse scroll still works" do
        screen.handle_event(mouse_event(kind: "scroll_up"))
        expect(screen.scroll_offset).to eq(10 - TUI::Screens::Chat::MOUSE_SCROLL_STEP)
      end
    end

    context "focus switching" do
      it "starts in input mode by default" do
        expect(screen.chat_focused).to be false
      end

      it "focus_chat enables chat focused mode" do
        screen.focus_chat
        expect(screen.chat_focused).to be true
      end

      it "unfocus_chat disables chat focused mode" do
        screen.focus_chat
        screen.unfocus_chat
        expect(screen.chat_focused).to be false
      end

      it "session_changed resets chat focus" do
        screen.focus_chat
        allow(cable_client).to receive(:drain_messages).and_return([
          {"action" => "session_changed", "session_id" => 99, "message_count" => 0}
        ])
        screen.send(:process_incoming_messages)
        expect(screen.chat_focused).to be false
      end
    end

    context "input history" do
      before do
        allow(cable_client).to receive(:recall_pending)
      end

      it "saves submitted messages to history" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        history = screen.instance_variable_get(:@input_history)
        expect(history).to eq(["hi"])
      end

      it "skips consecutive duplicates" do
        2.times do
          set_input("hello")
          screen.handle_event(key_event(code: "enter"))
        end

        history = screen.instance_variable_get(:@input_history)
        expect(history).to eq(["hello"])
      end

      it "navigates back through history on arrow up with empty input" do
        set_input("first")
        screen.handle_event(key_event(code: "enter"))
        set_input("second")
        screen.handle_event(key_event(code: "enter"))

        expect(screen.handle_event(key_event(code: "up"))).to be true
        expect(screen.input).to eq("second")
      end

      it "navigates to older entries on repeated arrow up" do
        set_input("first")
        screen.handle_event(key_event(code: "enter"))
        set_input("second")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        screen.handle_event(key_event(code: "up"))
        expect(screen.input).to eq("first")
      end

      it "returns false at the oldest history entry" do
        set_input("only")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        expect(screen.handle_event(key_event(code: "up"))).to be false
      end

      it "returns false when history is empty" do
        expect(screen.handle_event(key_event(code: "up"))).to be false
      end

      it "navigates forward through history on arrow down" do
        set_input("first")
        screen.handle_event(key_event(code: "enter"))
        set_input("second")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up")) # second
        screen.handle_event(key_event(code: "up")) # first
        screen.handle_event(key_event(code: "down")) # second
        expect(screen.input).to eq("second")
      end

      it "restores saved input when navigating past newest entry" do
        set_input("first")
        screen.handle_event(key_event(code: "enter"))

        set_input("work in progress")
        screen.handle_event(key_event(code: "up")) # first
        screen.handle_event(key_event(code: "down")) # restore
        expect(screen.input).to eq("work in progress")
      end

      it "returns false for arrow down when not browsing history" do
        expect(screen.handle_event(key_event(code: "down"))).to be false
      end

      it "saves original input before browsing" do
        set_input("first")
        screen.handle_event(key_event(code: "enter"))

        set_input("unsent draft")
        screen.handle_event(key_event(code: "up"))

        saved = screen.instance_variable_get(:@saved_input)
        expect(saved).to eq("unsent draft")
      end

      it "resets history browsing on character insert" do
        set_input("msg")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        screen.handle_event(key_event(code: "x"))

        expect(screen.instance_variable_get(:@history_index)).to be_nil
      end

      it "resets history browsing on backspace" do
        set_input("msg")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        screen.handle_event(key_event(code: "backspace"))

        expect(screen.instance_variable_get(:@history_index)).to be_nil
      end

      it "resets history browsing on delete" do
        set_input("msg")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        # Move cursor to start so delete has something to delete
        screen.handle_event(key_event(code: "home"))
        screen.handle_event(key_event(code: "delete"))

        expect(screen.instance_variable_get(:@history_index)).to be_nil
      end

      it "resets history browsing on paste" do
        set_input("msg")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        screen.handle_event(paste_event(content: "pasted"))

        expect(screen.instance_variable_get(:@history_index)).to be_nil
      end

      it "does not reset history browsing on cursor movement" do
        set_input("msg")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        screen.handle_event(key_event(code: "left"))

        expect(screen.instance_variable_get(:@history_index)).not_to be_nil
      end

      it "resets history browsing on submit" do
        set_input("msg")
        screen.handle_event(key_event(code: "enter"))

        screen.handle_event(key_event(code: "up"))
        screen.handle_event(key_event(code: "enter"))

        expect(screen.instance_variable_get(:@history_index)).to be_nil
      end

      it "pending recall takes priority when input is empty" do
        set_input("sent")
        screen.handle_event(key_event(code: "enter"))

        message_store.process_event({"type" => "user_message", "id" => 42,
                                     "rendered" => {"basic" => {"role" => "user", "content" => "pending msg", "status" => "pending"}}})

        screen.handle_event(key_event(code: "up"))
        expect(screen.input).to eq("pending msg")
        expect(cable_client).to have_received(:recall_pending).with(42)
      end
    end

    context "multiline input with history overflow" do
      before do
        allow(cable_client).to receive(:recall_pending)
      end

      it "tries move_up within multiline text before history" do
        set_input("sent")
        screen.handle_event(key_event(code: "enter"))

        set_input("line1\nline2", cursor_pos: 8) # cursor on line2
        expect(screen.handle_event(key_event(code: "up"))).to be true
        # Should have moved up within the input, not into history
        expect(screen.instance_variable_get(:@history_index)).to be_nil
      end

      it "overflows to history when at top line of multiline input" do
        set_input("sent")
        screen.handle_event(key_event(code: "enter"))

        set_input("line1\nline2", cursor_pos: 2) # cursor on line1
        screen.handle_event(key_event(code: "up"))
        expect(screen.input).to eq("sent")
      end

      it "tries move_down within multiline text before history forward" do
        set_input("sent")
        screen.handle_event(key_event(code: "enter"))

        # Start browsing history, get "sent" back, then make it multiline
        screen.handle_event(key_event(code: "up")) # load "sent"

        # Manually set multiline content to simulate user making edits
        set_input("sent\nextra", cursor_pos: 2) # cursor on line1

        expect(screen.handle_event(key_event(code: "down"))).to be true
        # Cursor should have moved down within input
        expect(screen.cursor_pos).to be > 2
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

      it "accepts paste while loading" do
        screen.instance_variable_set(:@loading, true)
        screen.handle_event(paste_event(content: "text"))
        expect(screen.input).to eq("text")
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

  describe "#interrupt_execution" do
    before { allow(cable_client).to receive(:interrupt) }

    it "sends interrupt via WebSocket protocol" do
      screen.interrupt_execution
      expect(cable_client).to have_received(:interrupt)
    end
  end

  describe "#input_title" do
    it "returns 'Input' by default" do
      expect(screen.send(:input_title)).to eq("Input")
    end

    it "returns 'Input' even when hud_hint is true" do
      screen.hud_hint = true
      expect(screen.send(:input_title)).to eq("Input")
    end

    it "returns 'Disconnected' when not connected" do
      allow(cable_client).to receive(:status).and_return(:disconnected)
      expect(screen.send(:input_title)).to eq("Disconnected")
    end
  end

  describe "#clear_input" do
    it "clears the input buffer" do
      screen.instance_variable_get(:@input_buffer).insert("hello world")
      expect(screen.input).to eq("hello world")

      screen.clear_input
      expect(screen.input).to eq("")
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

    it "updates session info including name" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.session_info).to eq({id: 99, name: nil, message_count: 5, active_skills: [], active_workflow: nil, goals: [], children: []})
    end

    it "stores session name from session_changed payload" do
      msg = session_changed_msg.merge("name" => "🔧 Debug Session")
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)
      expect(screen.session_info[:name]).to eq("🔧 Debug Session")
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

  describe "session_name_updated protocol message" do
    it "updates session name for the current session" do
      msg = {"action" => "session_name_updated", "session_id" => 42, "name" => "🎉 Chat Fun"}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:name]).to eq("🎉 Chat Fun")
    end

    it "ignores name updates for other sessions" do
      msg = {"action" => "session_name_updated", "session_id" => 999, "name" => "Other Session"}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:name]).to be_nil
    end
  end

  describe "active_skills_updated protocol message" do
    it "updates active skills for the current session" do
      msg = {"action" => "active_skills_updated", "session_id" => 42, "active_skills" => ["gh-issue", "activerecord"]}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_skills]).to eq(["gh-issue", "activerecord"])
    end

    it "ignores active skills updates for other sessions" do
      msg = {"action" => "active_skills_updated", "session_id" => 999, "active_skills" => ["gh-issue"]}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_skills]).to eq([])
    end

    it "stores active_skills from session_changed payload" do
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5,
             "active_skills" => ["rspec", "activerecord"]}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_skills]).to eq(["rspec", "activerecord"])
    end

    it "defaults active_skills to empty array when missing from session_changed" do
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_skills]).to eq([])
    end
  end

  describe "active_workflow_updated protocol message" do
    it "updates active workflow for the current session" do
      msg = {"action" => "active_workflow_updated", "session_id" => 42, "active_workflow" => "feature"}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_workflow]).to eq("feature")
    end

    it "ignores active workflow updates for other sessions" do
      msg = {"action" => "active_workflow_updated", "session_id" => 999, "active_workflow" => "feature"}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_workflow]).to be_nil
    end

    it "stores active_workflow from session_changed payload" do
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5,
             "active_workflow" => "review_pr"}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_workflow]).to eq("review_pr")
    end

    it "defaults active_workflow to nil when missing from session_changed" do
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:active_workflow]).to be_nil
    end

    it "clears active workflow on deactivation" do
      # First activate
      msg = {"action" => "active_workflow_updated", "session_id" => 42, "active_workflow" => "feature"}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)
      expect(screen.session_info[:active_workflow]).to eq("feature")

      # Then deactivate
      msg = {"action" => "active_workflow_updated", "session_id" => 42, "active_workflow" => nil}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)
      expect(screen.session_info[:active_workflow]).to be_nil
    end
  end

  describe "goals_updated protocol message" do
    it "updates goals for the current session" do
      goals = [{"id" => 1, "description" => "Implement auth", "status" => "active", "sub_goals" => []}]
      msg = {"action" => "goals_updated", "session_id" => 42, "goals" => goals}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:goals]).to eq(goals)
    end

    it "ignores goals updates for other sessions" do
      msg = {"action" => "goals_updated", "session_id" => 999, "goals" => [{"id" => 1}]}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:goals]).to eq([])
    end

    it "stores goals from session_changed payload" do
      goals = [{"id" => 1, "description" => "Test goal", "status" => "active", "sub_goals" => []}]
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5, "goals" => goals}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:goals]).to eq(goals)
    end

    it "defaults goals to empty array when missing from session_changed" do
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:goals]).to eq([])
    end
  end

  describe "children_updated protocol message" do
    it "updates children for the current session" do
      children = [{"id" => 101, "name" => "api-scout", "processing" => true}]
      msg = {"action" => "children_updated", "session_id" => 42, "children" => children}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:children]).to eq(children)
    end

    it "ignores children updates for other sessions" do
      msg = {"action" => "children_updated", "session_id" => 999, "children" => [{"id" => 101}]}
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:children]).to eq([])
    end

    it "stores children from session_changed payload" do
      children = [{"id" => 101, "name" => "scout", "processing" => false}]
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5, "children" => children}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:children]).to eq(children)
    end

    it "defaults children to empty array when missing from session_changed" do
      msg = {"action" => "session_changed", "session_id" => 99, "message_count" => 5}
      allow(cable_client).to receive(:update_session_id)
      allow(cable_client).to receive(:drain_messages).and_return([msg])
      screen.send(:process_incoming_messages)

      expect(screen.session_info[:children]).to eq([])
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

    describe "#switch_view_mode" do
      it "sends change_view_mode to cable_client with target mode" do
        screen.switch_view_mode("verbose")
        expect(cable_client).to have_received(:change_view_mode).with("verbose")
      end

      it "sends change_view_mode for debug mode" do
        screen.switch_view_mode("debug")
        expect(cable_client).to have_received(:change_view_mode).with("debug")
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

  describe "authentication signals" do
    it "sets authentication_required on authentication_required action" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "authentication_required", "message" => "No token"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.authentication_required).to be true
    end

    it "clears authentication_required and sets success result on token_saved" do
      screen.instance_variable_set(:@authentication_required, true)
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "token_saved"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.authentication_required).to be false
      expect(screen.token_save_result).to eq({success: true})
    end

    it "sets error result on token_error" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "token_error", "message" => "Invalid format"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.token_save_result).to eq({success: false, message: "Invalid format"})
    end

    describe "#clear_authentication_required" do
      it "clears the flag" do
        screen.instance_variable_set(:@authentication_required, true)
        screen.clear_authentication_required
        expect(screen.authentication_required).to be false
      end
    end

    describe "#consume_token_save_result" do
      it "returns and clears the result" do
        screen.instance_variable_set(:@token_save_result, {success: true})

        result = screen.consume_token_save_result
        expect(result).to eq({success: true})
        expect(screen.token_save_result).to be_nil
      end

      it "returns nil when no result" do
        expect(screen.consume_token_save_result).to be_nil
      end
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

  describe "bounce_back message processing" do
    let(:user_event) do
      {
        "type" => "user_message",
        "content" => "Hello, world!",
        "action" => "create",
        "id" => 99,
        "rendered" => {"basic" => {"role" => "user", "content" => "Hello, world!"}}
      }
    end

    before do
      # Simulate a user message already in the store
      allow(cable_client).to receive(:drain_messages).and_return([user_event])
      screen.send(:process_incoming_messages)
    end

    it "removes the bounced event from the message store" do
      expect(screen.messages.size).to eq(1)

      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "bounce_back", "event_id" => 99, "content" => "Hello, world!", "message" => "Auth failed"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.messages).to be_empty
    end

    it "restores the bounced content to the input buffer" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "bounce_back", "event_id" => 99, "content" => "Hello, world!", "message" => "Auth failed"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.input).to eq("Hello, world!")
    end

    it "clears loading state" do
      # Set loading
      screen.instance_variable_set(:@loading, true)

      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "bounce_back", "event_id" => 99, "content" => "Hello, world!", "message" => "Auth failed"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.loading?).to be false
    end

    it "adds a flash notification with the error message" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "bounce_back", "event_id" => 99, "content" => "Hello, world!", "message" => "Auth failed"}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.flash_messages.size).to eq(1)
      flash = screen.flash_messages.first
      expect(flash[:content]).to include("Auth failed")
      expect(flash[:type]).to eq(:error)
      expect(flash[:expires_at]).to be_within(1).of(Time.now + Anima::Settings.flash_timeout)
    end

    it "handles bounce without event_id gracefully" do
      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "bounce_back", "content" => "Hello!", "message" => "Error"}
      ])
      screen.send(:process_incoming_messages)

      # Original event stays (no matching ID to remove)
      expect(screen.messages.size).to eq(1)
      expect(screen.input).to eq("Hello!")
      expect(screen.flash_messages.size).to eq(1)
    end
  end

  describe "flash messages" do
    it "expires flash messages after timeout" do
      screen.send(:add_flash, "Test flash", :info)
      expect(screen.flash_messages.size).to eq(1)

      # Set expiry to the past
      screen.flash_messages.first[:expires_at] = Time.now - 1

      screen.send(:expire_flash_messages)
      expect(screen.flash_messages).to be_empty
    end

    it "dismisses flash on keypress" do
      screen.send(:add_flash, "Test flash", :info)
      expect(screen.flash_messages.size).to eq(1)

      screen.handle_event(key_event(code: "a"))
      expect(screen.flash_messages).to be_empty
    end

    it "dismisses flash on paste event" do
      screen.send(:add_flash, "Test flash", :info)
      expect(screen.flash_messages.size).to eq(1)

      screen.handle_event(paste_event(content: "pasted text"))
      expect(screen.flash_messages).to be_empty
    end

    it "clears flash messages on session change" do
      screen.send(:add_flash, "Test flash", :info)

      allow(cable_client).to receive(:drain_messages).and_return([
        {"action" => "session_changed", "session_id" => 99, "message_count" => 0}
      ])
      screen.send(:process_incoming_messages)

      expect(screen.flash_messages).to be_empty
    end
  end
end
