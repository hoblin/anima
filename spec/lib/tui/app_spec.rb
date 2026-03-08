# frozen_string_literal: true

require "rails_helper"
require "ratatui_ruby"

RSpec.describe TUI::App do
  subject(:app) { described_class.new }

  describe "#initialize" do
    it "starts on the chat screen" do
      expect(app.current_screen).to eq(:chat)
    end

    it "starts in normal mode" do
      expect(app.command_mode).to be false
    end
  end

  describe "event handling" do
    # RatatuiRuby::Event uses method_missing for dynamic predicates,
    # so we use plain doubles instead of instance_double
    def key_event(code:, modifiers: nil, **overrides)
      defaults = {
        none?: false, ctrl_c?: false, key?: true, esc?: false,
        enter?: false, backspace?: false
      }
      defaults[:esc?] = true if code == "esc"
      defaults[:enter?] = true if code == "enter"
      defaults[:backspace?] = true if code == "backspace"
      double("Event", **defaults, code: code, modifiers: modifiers, **overrides)
    end

    describe "Ctrl+C exits" do
      it "returns :quit" do
        event = double("Event", none?: false, ctrl_c?: true)
        result = app.send(:handle_event, event)
        expect(result).to eq(:quit)
      end
    end

    describe "command mode activation" do
      it "enters command mode on Ctrl+a" do
        event = key_event(code: "a", modifiers: ["ctrl"])
        app.send(:handle_event, event)
        expect(app.command_mode).to be true
      end
    end

    describe "command mode actions" do
      before { app.instance_variable_set(:@command_mode, true) }

      it "navigates to settings on 's'" do
        event = key_event(code: "s")
        app.send(:handle_event, event)
        expect(app.current_screen).to eq(:settings)
        expect(app.command_mode).to be false
      end

      it "navigates to anthropic on 'a'" do
        event = key_event(code: "a")
        app.send(:handle_event, event)
        expect(app.current_screen).to eq(:anthropic)
        expect(app.command_mode).to be false
      end

      it "starts new session on 'n'" do
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:new_session)

        event = key_event(code: "n")
        app.send(:handle_event, event)

        expect(chat).to have_received(:new_session)
        expect(app.current_screen).to eq(:chat)
        expect(app.command_mode).to be false
      end

      it "returns to chat screen on 'n' from other screens" do
        app.instance_variable_set(:@current_screen, :settings)
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:new_session)

        event = key_event(code: "n")
        app.send(:handle_event, event)

        expect(app.current_screen).to eq(:chat)
      end

      it "quits on 'q'" do
        event = key_event(code: "q")
        result = app.send(:handle_event, event)
        expect(result).to eq(:quit)
      end

      it "exits command mode on any unrecognized key" do
        event = key_event(code: "x")
        app.send(:handle_event, event)
        expect(app.command_mode).to be false
      end

      it "exits command mode on non-key events" do
        event = double("Event", none?: false, ctrl_c?: false, key?: false)
        app.send(:handle_event, event)
        expect(app.command_mode).to be false
      end
    end

    describe "Esc returns to chat from other screens" do
      it "returns to chat from settings" do
        app.instance_variable_set(:@current_screen, :settings)
        event = key_event(code: "esc")
        app.send(:handle_event, event)
        expect(app.current_screen).to eq(:chat)
      end

      it "stays on chat when already there" do
        event = key_event(code: "esc")
        app.send(:handle_event, event)
        expect(app.current_screen).to eq(:chat)
      end
    end

    describe "screen event delegation" do
      it "delegates key events to the current screen's handle_event" do
        app.instance_variable_set(:@current_screen, :settings)
        event = key_event(code: "j")
        settings = app.instance_variable_get(:@screens)[:settings]
        allow(settings).to receive(:handle_event)

        app.send(:handle_event, event)

        expect(settings).to have_received(:handle_event).with(event)
      end

      it "delegates key events to chat screen's handle_event" do
        event = key_event(code: "a")
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, event)

        expect(chat).to have_received(:handle_event).with(event)
      end

      it "does not delegate to screens without handle_event" do
        app.instance_variable_set(:@current_screen, :anthropic)
        event = key_event(code: "j")
        expect { app.send(:handle_event, event) }.not_to raise_error
      end
    end

    describe "no-op on none events" do
      it "returns nil" do
        event = double("Event", none?: true)
        result = app.send(:handle_event, event)
        expect(result).to be_nil
      end
    end
  end
end
