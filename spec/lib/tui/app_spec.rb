# frozen_string_literal: true

require "spec_helper"
require "ratatui_ruby"
require "tui/app"

RSpec.describe TUI::App do
  let(:cable_client) do
    instance_double(TUI::CableClient, host: "localhost:42134", session_id: 42, status: :subscribed, disconnect: nil)
  end

  subject(:app) { described_class.new(cable_client: cable_client) }

  before do
    allow(cable_client).to receive(:drain_messages).and_return([])
    allow(cable_client).to receive(:speak)
  end

  describe "#initialize" do
    it "starts on the chat screen" do
      expect(app.current_screen).to eq(:chat)
    end

    it "starts in normal mode" do
      expect(app.command_mode).to be false
    end

    it "starts with shutdown not requested" do
      expect(app.shutdown_requested).to be false
    end
  end

  describe "event handling" do
    # RatatuiRuby::Event uses method_missing for dynamic predicates,
    # so we use plain doubles instead of instance_double
    def key_event(code:, modifiers: nil, **overrides)
      defaults = {
        none?: false, ctrl_c?: false, key?: true, mouse?: false, paste?: false,
        esc?: false, enter?: false, backspace?: false, delete?: false,
        up?: false, down?: false, page_up?: false, page_down?: false,
        left?: false, right?: false, home?: false, end?: false
      }
      defaults[:esc?] = true if code == "esc"
      defaults[:enter?] = true if code == "enter"
      defaults[:backspace?] = true if code == "backspace"
      defaults[:delete?] = true if code == "delete"
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

      it "starts new session on 'n'" do
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:new_session)

        event = key_event(code: "n")
        app.send(:handle_event, event)

        expect(chat).to have_received(:new_session)
        expect(app.current_screen).to eq(:chat)
        expect(app.command_mode).to be false
      end

      it "cycles view mode on 'v'" do
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:cycle_view_mode)

        event = key_event(code: "v")
        app.send(:handle_event, event)

        expect(chat).to have_received(:cycle_view_mode)
        expect(app.current_screen).to eq(:chat)
        expect(app.command_mode).to be false
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

    describe "screen event delegation" do
      it "delegates key events to chat screen's handle_event" do
        event = key_event(code: "a")
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, event)

        expect(chat).to have_received(:handle_event).with(event)
      end

      it "delegates mouse events to the current screen" do
        event = double("MouseEvent", none?: false, ctrl_c?: false, key?: false, mouse?: true)
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, event)

        expect(chat).to have_received(:handle_event).with(event)
      end

      it "delegates paste events to the current screen" do
        event = double("PasteEvent", none?: false, ctrl_c?: false, key?: false, mouse?: false, paste?: true,
          content: "pasted text")
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, event)

        expect(chat).to have_received(:handle_event).with(event)
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

  describe "signal handling" do
    let(:captured_handlers) { {} }

    before do
      allow(Signal).to receive(:trap) do |signal, *args, &block|
        captured_handlers[signal] = block || args.first
        "DEFAULT"
      end
    end

    describe "install_signal_handlers" do
      it "traps HUP, TERM, and INT signals" do
        app.send(:install_signal_handlers)

        expect(Signal).to have_received(:trap).with("HUP", any_args)
        expect(Signal).to have_received(:trap).with("TERM", any_args)
        expect(Signal).to have_received(:trap).with("INT", any_args)
      end

      it "saves previous handler return values" do
        app.send(:install_signal_handlers)

        handlers = app.instance_variable_get(:@previous_signal_handlers)
        expect(handlers.keys).to contain_exactly("HUP", "TERM", "INT")
        expect(handlers.values).to all(eq("DEFAULT"))
      end

      it "sets shutdown_requested when any handler fires" do
        app.send(:install_signal_handlers)

        %w[HUP TERM INT].each do |signal|
          app.instance_variable_set(:@shutdown_requested, false)
          captured_handlers[signal].call
          expect(app.shutdown_requested).to be(true), "expected #{signal} handler to set shutdown_requested"
        end
      end

      it "skips unsupported signals without raising" do
        allow(Signal).to receive(:trap).with("HUP").and_raise(ArgumentError)
        allow(Signal).to receive(:trap).with("TERM") do |_, &block|
          captured_handlers["TERM"] = block
          "DEFAULT"
        end
        allow(Signal).to receive(:trap).with("INT") do |_, &block|
          captured_handlers["INT"] = block
          "DEFAULT"
        end

        expect { app.send(:install_signal_handlers) }.not_to raise_error

        handlers = app.instance_variable_get(:@previous_signal_handlers)
        expect(handlers.keys).to contain_exactly("TERM", "INT")
      end
    end

    describe "restore_signal_handlers" do
      it "restores previously saved handlers" do
        previous = {"HUP" => "DEFAULT", "TERM" => proc {}, "INT" => "IGNORE"}
        app.instance_variable_set(:@previous_signal_handlers, previous)

        app.send(:restore_signal_handlers)

        previous.each do |signal, handler|
          expect(Signal).to have_received(:trap).with(signal, handler)
        end
      end

      it "uses DEFAULT when previous handler was nil" do
        app.instance_variable_set(:@previous_signal_handlers, {"HUP" => nil})

        app.send(:restore_signal_handlers)

        expect(Signal).to have_received(:trap).with("HUP", "DEFAULT")
      end

      it "skips unrestorable signals without raising" do
        app.instance_variable_set(:@previous_signal_handlers, {"HUP" => "DEFAULT"})
        allow(Signal).to receive(:trap).with("HUP", "DEFAULT").and_raise(ArgumentError)

        expect { app.send(:restore_signal_handlers) }.not_to raise_error
      end

      it "does not leave shutdown flag set" do
        app.send(:install_signal_handlers)
        app.send(:restore_signal_handlers)

        expect(app.shutdown_requested).to be false
      end
    end
  end

  describe "terminal watchdog" do
    # Stubs File.open for the controlling terminal path.
    # Yields to the block (like the real File.open with {}) on success,
    # or raises on failure.
    def stub_terminal_open(succeeds: true, error: Errno::ENXIO)
      allow(File).to receive(:open).and_call_original
      stub = allow(File).to receive(:open).with(TUI::App::CONTROLLING_TERMINAL, "r")
      if succeeds
        stub.and_yield
      else
        stub.and_raise(error)
      end
    end

    describe "start_terminal_watchdog" do
      before { stub_terminal_open(succeeds: false) }
      after { app.send(:stop_terminal_watchdog) }

      it "starts a background thread" do
        app.send(:start_terminal_watchdog)

        watchdog = app.instance_variable_get(:@watchdog_thread)
        expect(watchdog).to be_a(Thread)
      end

      it "thread exits when terminal is unavailable" do
        app.send(:start_terminal_watchdog)
        watchdog = app.instance_variable_get(:@watchdog_thread)
        watchdog.join(1)

        expect(watchdog.status).to be false
      end
    end

    describe "stop_terminal_watchdog" do
      it "clears the watchdog thread reference" do
        stub_terminal_open(succeeds: false)
        app.send(:start_terminal_watchdog)
        app.send(:stop_terminal_watchdog)

        expect(app.instance_variable_get(:@watchdog_thread)).to be_nil
      end

      it "is safe to call when no watchdog is running" do
        expect { app.send(:stop_terminal_watchdog) }.not_to raise_error
      end
    end

    describe "terminal_watchdog_loop" do
      it "exits loop when shutdown_requested is set" do
        stub_terminal_open(succeeds: true)
        app.instance_variable_set(:@shutdown_requested, true)

        expect { app.send(:terminal_watchdog_loop) }.not_to raise_error
      end

      it "exits silently without a controlling terminal" do
        stub_terminal_open(succeeds: false)

        expect { app.send(:terminal_watchdog_loop) }.not_to raise_error
      end

      it "calls handle_terminal_loss when terminal disappears mid-loop (ENXIO)" do
        call_count = 0
        allow(File).to receive(:open).and_call_original
        allow(File).to receive(:open).with(TUI::App::CONTROLLING_TERMINAL, "r") do
          call_count += 1
          raise Errno::ENXIO if call_count > 1
        end
        allow(app).to receive(:sleep)
        allow(app).to receive(:handle_terminal_loss) { throw :force_exit }

        catch(:force_exit) { app.send(:terminal_watchdog_loop) }

        expect(app).to have_received(:handle_terminal_loss)
      end

      it "calls handle_terminal_loss when terminal disappears mid-loop (EIO)" do
        call_count = 0
        allow(File).to receive(:open).and_call_original
        allow(File).to receive(:open).with(TUI::App::CONTROLLING_TERMINAL, "r") do
          call_count += 1
          raise Errno::EIO if call_count > 1
        end
        allow(app).to receive(:sleep)
        allow(app).to receive(:handle_terminal_loss) { throw :force_exit }

        catch(:force_exit) { app.send(:terminal_watchdog_loop) }

        expect(app).to have_received(:handle_terminal_loss)
      end
    end

    describe "handle_terminal_loss" do
      it "attempts cable disconnect" do
        allow(Kernel).to receive(:exit!)

        app.send(:handle_terminal_loss)

        expect(cable_client).to have_received(:disconnect)
      end

      it "tolerates disconnect failure" do
        allow(cable_client).to receive(:disconnect).and_raise(IOError)
        allow(Kernel).to receive(:exit!)

        expect { app.send(:handle_terminal_loss) }.not_to raise_error
      end
    end
  end

  describe "connection status" do
    it "defines styles for all connection states including reconnecting" do
      expect(TUI::App::STATUS_STYLES).to include(
        :disconnected, :connecting, :connected, :subscribed, :reconnecting
      )
    end
  end
end
