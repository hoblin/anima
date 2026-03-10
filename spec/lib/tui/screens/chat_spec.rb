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
  end

  # RatatuiRuby::Event uses method_missing for dynamic predicates,
  # so we use plain doubles instead of instance_double
  def key_event(code:, modifiers: nil, **overrides)
    defaults = {
      key?: true, mouse?: false, enter?: false, backspace?: false, esc?: false,
      none?: false, ctrl_c?: false, up?: false, down?: false,
      page_up?: false, page_down?: false
    }
    defaults[:enter?] = true if code == "enter"
    defaults[:backspace?] = true if code == "backspace"
    defaults[:esc?] = true if code == "esc"
    defaults[:up?] = true if code == "up"
    defaults[:down?] = true if code == "down"
    defaults[:page_up?] = true if code == "page_up"
    defaults[:page_down?] = true if code == "page_down"
    double("Event", **defaults, code: code, modifiers: modifiers, **overrides)
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

      it "stops accepting input at MAX_INPUT_LENGTH" do
        screen.instance_variable_set(:@input, "a" * described_class::MAX_INPUT_LENGTH)
        expect(screen.handle_event(key_event(code: "x"))).to be false
        expect(screen.input.length).to eq(described_class::MAX_INPUT_LENGTH)
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

        expect(screen.messages).to eq([
          {role: "user", content: "hello"},
          {role: "assistant", content: "hi there"}
        ])
      end

      it "does not store connection status messages as chat messages" do
        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribed"}
        ])

        screen.send(:process_incoming_messages)

        expect(screen.messages).to be_empty
      end
    end

    context "connection lifecycle events" do
      it "clears message store on subscribed" do
        message_store.process_event({"type" => "user_message", "content" => "old"})

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribed"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages).to be_empty
      end

      it "resets loading on subscribed" do
        screen.instance_variable_set(:@loading, true)

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribed"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.loading?).to be false
      end

      it "resets message count on subscribed" do
        screen.instance_variable_get(:@session_info)[:message_count] = 5

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribed"}
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

        allow(cable_client).to receive(:drain_messages).and_return([
          {"type" => "connection", "status" => "subscribed"},
          {"type" => "user_message", "content" => "restored"},
          {"type" => "agent_message", "content" => "response"}
        ])
        screen.send(:process_incoming_messages)

        expect(screen.messages).to eq([
          {role: "user", content: "restored"},
          {role: "assistant", content: "response"}
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

  describe "session_changed protocol message" do
    before do
      message_store.process_event({"type" => "user_message", "content" => "old message"})
      screen.instance_variable_set(:@input, "partial")
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

    it "clears input" do
      allow(cable_client).to receive(:drain_messages).and_return([session_changed_msg])
      screen.send(:process_incoming_messages)
      expect(screen.input).to eq("")
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
end
