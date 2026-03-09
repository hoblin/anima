# frozen_string_literal: true

require "rails_helper"
require "ratatui_ruby"

RSpec.describe TUI::Screens::Chat do
  let(:session) { Session.create! }
  let(:persister) { double("Persister", emit: nil, session: session, "session=": nil) }

  subject(:screen) { described_class.new(session: session, persister: persister) }

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

  after { screen.finalize }

  describe "#initialize" do
    it "starts with empty messages for a fresh session" do
      expect(screen.messages).to eq([])
    end

    it "starts with empty input" do
      expect(screen.input).to eq("")
    end

    it "starts not loading" do
      expect(screen.loading?).to be false
    end

    it "subscribes the message collector to the event bus" do
      screen # force lazy subject to initialize and subscribe
      Events::Bus.emit(Events::UserMessage.new(content: "test"))
      expect(screen.messages).to eq([{role: "user", content: "test"}])
    end

    it "resumes messages from an existing session" do
      session.events.create!(event_type: "user_message", payload: {"content" => "old message"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2)

      resumed_screen = described_class.new(session: session, persister: persister)

      expect(resumed_screen.messages).to eq([
        {role: "user", content: "old message"},
        {role: "assistant", content: "old reply"}
      ])

      resumed_screen.finalize
    end

    it "skips tool events when resuming a session" do
      session.events.create!(event_type: "user_message", payload: {"content" => "fetch example.com"}, timestamp: 1)
      session.events.create!(event_type: "tool_call", payload: {"content" => "Calling web_get", "tool_name" => "web_get", "tool_use_id" => "toolu_1"}, timestamp: 2)
      session.events.create!(event_type: "tool_response", payload: {"content" => "<html>...</html>", "tool_name" => "web_get", "tool_use_id" => "toolu_1", "success" => true}, timestamp: 3)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Here is the content"}, timestamp: 4)

      resumed_screen = described_class.new(session: session, persister: persister)

      expect(resumed_screen.messages).to eq([
        {role: "user", content: "fetch example.com"},
        {role: "assistant", content: "Here is the content"}
      ])

      resumed_screen.finalize
    end

    it "creates a session if none exists" do
      Session.destroy_all
      new_screen = described_class.new(persister: persister)
      expect(new_screen.session).to be_a(Session)
      expect(new_screen.session).to be_persisted
      new_screen.finalize
    end

    it "resumes the last session if one exists" do
      resumed_screen = described_class.new(persister: persister)
      expect(resumed_screen.session).to eq(session)
      resumed_screen.finalize
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

    context "enter submits message" do
      let(:client) { double("LLM::Client") }
      let(:agent_loop) { AgentLoop.new(session: session, client: client) }

      subject(:screen) { described_class.new(session: session, persister: persister, agent_loop: agent_loop) }

      before do
        allow(client).to receive(:chat_with_tools).and_return("Hello back!")
      end

      it "emits user_message event and collects it" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.messages.first).to eq({role: "user", content: "hi"})
      end

      it "clears input after submit" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))
        expect(screen.input).to eq("")
      end

      it "emits agent_message event and collects response" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.messages.last).to eq({role: "assistant", content: "Hello back!"})
      end

      it "sets loading to true during LLM call" do
        allow(client).to receive(:chat_with_tools) do
          sleep 0.2
          "response"
        end

        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        expect(screen.loading?).to be true
      end

      it "sets loading to false after LLM call completes" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.loading?).to be false
      end

      it "does not submit empty input" do
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.messages).to be_empty
        expect(client).not_to have_received(:chat_with_tools)
      end

      it "does not submit whitespace-only input" do
        screen.handle_event(key_event(code: " "))
        screen.handle_event(key_event(code: " "))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.messages).to be_empty
      end

      it "returns true" do
        screen.handle_event(key_event(code: "h"))
        expect(screen.handle_event(key_event(code: "enter"))).to be true
      end
    end

    context "error handling" do
      let(:client) { double("LLM::Client") }
      let(:agent_loop) { AgentLoop.new(session: session, client: client) }

      subject(:screen) { described_class.new(session: session, persister: persister, agent_loop: agent_loop) }

      before do
        allow(client).to receive(:chat_with_tools).and_raise(StandardError, "Connection failed")
      end

      it "emits error as agent_message event" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.messages.last).to eq({role: "assistant", content: "StandardError: Connection failed"})
      end

      it "resets loading after error" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.loading?).to be false
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

    context "multi-turn conversation" do
      let(:real_persister) { Events::Subscribers::Persister.new(session) }
      let(:client) { double("LLM::Client") }
      let(:agent_loop) { AgentLoop.new(session: session, client: client) }
      let(:screen_with_persister) { described_class.new(session: session, persister: real_persister, agent_loop: agent_loop) }

      after { screen_with_persister.finalize }

      it "passes viewport messages from session to LLM client" do
        received_messages = nil
        allow(client).to receive(:chat_with_tools).and_return("First response")
        screen_with_persister.handle_event(key_event(code: "a"))
        screen_with_persister.handle_event(key_event(code: "enter"))
        sleep 0.1

        allow(client).to receive(:chat_with_tools) { |msgs, **_opts|
          received_messages = msgs.dup
          "Second response"
        }
        screen_with_persister.handle_event(key_event(code: "b"))
        screen_with_persister.handle_event(key_event(code: "enter"))
        sleep 0.1

        expect(received_messages).to eq([
          {role: "user", content: "a"},
          {role: "assistant", content: "First response"},
          {role: "user", content: "b"}
        ])
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
    let(:client) { double("LLM::Client") }
    let(:agent_loop) { AgentLoop.new(session: session, client: client) }

    subject(:screen) { described_class.new(session: session, persister: persister, agent_loop: agent_loop) }

    after { screen.finalize }

    before do
      allow(client).to receive(:chat_with_tools).and_return("response")

      screen.handle_event(key_event(code: "h"))
      screen.handle_event(key_event(code: "i"))
      screen.handle_event(key_event(code: "enter"))
      sleep 0.1
    end

    it "clears messages" do
      screen.new_session
      expect(screen.messages).to eq([])
    end

    it "creates a new session record" do
      expect { screen.new_session }.to change(Session, :count).by(1)
    end

    it "switches the persister to the new session" do
      screen.new_session
      expect(persister).to have_received(:session=)
    end

    it "clears input" do
      screen.instance_variable_set(:@input, "partial")
      screen.new_session
      expect(screen.input).to eq("")
    end

    it "resets loading state" do
      screen.instance_variable_set(:@loading, true)
      screen.new_session
      expect(screen.loading?).to be false
    end

    it "resets scroll state" do
      screen.instance_variable_set(:@scroll_offset, 15)
      screen.instance_variable_set(:@auto_scroll, false)
      screen.new_session
      expect(screen.scroll_offset).to eq(0)
      expect(screen.instance_variable_get(:@auto_scroll)).to be true
    end
  end

  describe "#finalize" do
    it "unsubscribes the message collector from the event bus" do
      screen.finalize
      Events::Bus.emit(Events::UserMessage.new(content: "after finalize"))
      expect(screen.messages).to be_empty
    end

    it "unsubscribes the persister from the event bus" do
      expect { screen.finalize }.not_to raise_error
    end
  end
end
