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
    allow(cable_client).to receive(:list_sessions)
    allow(cable_client).to receive(:switch_session)
    allow(cable_client).to receive(:change_view_mode)
    allow(cable_client).to receive(:save_token)
  end

  describe "#initialize" do
    it "starts on the chat screen" do
      expect(app.current_screen).to eq(:chat)
    end

    it "starts in normal mode" do
      expect(app.command_mode).to be false
    end

    it "starts with session picker inactive" do
      expect(app.session_picker_active).to be false
    end

    it "starts with view mode picker inactive" do
      expect(app.view_mode_picker_active).to be false
    end

    it "starts with token setup inactive" do
      expect(app.token_setup_active).to be false
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

      it "opens token setup on 'a'" do
        event = key_event(code: "a")
        app.send(:handle_event, event)

        expect(app.token_setup_active).to be true
        expect(app.command_mode).to be false
      end

      it "opens view mode picker on 'v'" do
        event = key_event(code: "v")
        app.send(:handle_event, event)

        expect(app.view_mode_picker_active).to be true
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

      it "opens session picker on 's'" do
        event = key_event(code: "s")
        app.send(:handle_event, event)

        expect(app.session_picker_active).to be true
        expect(app.command_mode).to be false
        expect(cable_client).to have_received(:list_sessions)
      end
    end

    describe "session picker" do
      let(:sessions) do
        [
          {"id" => 10, "message_count" => 5, "updated_at" => Time.now.iso8601},
          {"id" => 8, "message_count" => 3, "updated_at" => Time.now.iso8601,
           "children" => [
             {"id" => 81, "name" => "codebase-analyzer", "processing" => false, "message_count" => 2, "created_at" => Time.now.iso8601},
             {"id" => 82, "name" => nil, "processing" => true, "message_count" => 1, "created_at" => Time.now.iso8601}
           ]},
          {"id" => 5, "message_count" => 0, "updated_at" => Time.now.iso8601}
        ]
      end

      before do
        app.instance_variable_set(:@command_mode, true)
        app.send(:handle_event, key_event(code: "s"))

        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@sessions_list, sessions)

        allow(chat).to receive(:switch_session)
      end

      it "closes on Escape" do
        app.send(:handle_event, key_event(code: "esc", esc?: true))
        expect(app.session_picker_active).to be false
      end

      it "moves selection down on arrow down" do
        app.send(:handle_event, key_event(code: "down"))
        expect(app.instance_variable_get(:@session_picker_index)).to eq(1)
      end

      it "moves selection up on arrow up" do
        app.send(:handle_event, key_event(code: "down"))
        app.send(:handle_event, key_event(code: "up"))
        expect(app.instance_variable_get(:@session_picker_index)).to eq(0)
      end

      it "clamps selection at top" do
        app.send(:handle_event, key_event(code: "up"))
        expect(app.instance_variable_get(:@session_picker_index)).to eq(0)
      end

      it "clamps selection at bottom" do
        5.times { app.send(:handle_event, key_event(code: "down")) }
        expect(app.instance_variable_get(:@session_picker_index)).to eq(2)
      end

      it "switches session on Enter" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "enter"))

        expect(chat).to have_received(:switch_session).with(10)
        expect(app.session_picker_active).to be false
      end

      it "switches to second session on Enter after moving down" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "down"))
        app.send(:handle_event, key_event(code: "enter"))

        expect(chat).to have_received(:switch_session).with(8)
      end

      it "switches session on digit hotkey 1" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "1"))

        expect(chat).to have_received(:switch_session).with(10)
        expect(app.session_picker_active).to be false
      end

      it "switches session on digit hotkey 2" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "2"))

        expect(chat).to have_received(:switch_session).with(8)
      end

      it "switches session on digit hotkey 3" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "3"))

        expect(chat).to have_received(:switch_session).with(5)
      end

      it "ignores digit hotkey beyond list size" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "9"))

        expect(chat).not_to have_received(:switch_session)
        expect(app.session_picker_active).to be true
      end

      it "does not delegate events to chat screen while picker is active" do
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, key_event(code: "a"))

        expect(chat).not_to have_received(:handle_event)
      end

      describe "tree navigation" do
        it "expands children on right arrow for session with children" do
          # Move to session #8 (index 1) which has children
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))

          expanded = app.instance_variable_get(:@expanded_sessions)
          expect(expanded[8]).to be true
        end

        it "does not expand on right arrow for session without children" do
          # Session #10 (index 0) has no children
          app.send(:handle_event, key_event(code: "right"))

          expanded = app.instance_variable_get(:@expanded_sessions)
          expect(expanded[10]).to be_nil
        end

        it "shows children in visible items after expansion" do
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))

          visible = app.send(:session_picker_visible_items)
          types = visible.map { |i| i[:type] }
          # root, root(expanded), child, child, root
          expect(types).to eq([:root, :root, :child, :child, :root])
        end

        it "navigates into expanded children" do
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))
          app.send(:handle_event, key_event(code: "down"))

          # Should now be on the first child (codebase-analyzer)
          visible = app.send(:session_picker_visible_items)
          idx = app.instance_variable_get(:@session_picker_index)
          expect(visible[idx][:type]).to eq(:child)
          expect(visible[idx][:data]["id"]).to eq(81)
        end

        it "switches to child session on Enter" do
          chat = app.instance_variable_get(:@screens)[:chat]
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "enter"))

          expect(chat).to have_received(:switch_session).with(81)
        end

        it "collapses on left arrow from parent" do
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))
          app.send(:handle_event, key_event(code: "left"))

          expanded = app.instance_variable_get(:@expanded_sessions)
          expect(expanded).not_to have_key(8)
        end

        it "collapses parent and moves to parent on left arrow from child" do
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))
          app.send(:handle_event, key_event(code: "down")) # on first child
          app.send(:handle_event, key_event(code: "left"))

          expanded = app.instance_variable_get(:@expanded_sessions)
          expect(expanded).not_to have_key(8)

          idx = app.instance_variable_get(:@session_picker_index)
          visible = app.send(:session_picker_visible_items)
          expect(visible[idx][:data]["id"]).to eq(8)
        end

        it "clamps selection at bottom of expanded list" do
          app.send(:handle_event, key_event(code: "down"))
          app.send(:handle_event, key_event(code: "right"))
          # Now 5 items visible, try moving past end
          10.times { app.send(:handle_event, key_event(code: "down")) }

          visible = app.send(:session_picker_visible_items)
          idx = app.instance_variable_get(:@session_picker_index)
          expect(idx).to eq(visible.size - 1)
        end
      end
    end

    describe "view mode picker" do
      before do
        app.instance_variable_set(:@command_mode, true)
        app.send(:handle_event, key_event(code: "v"))

        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:switch_view_mode)
      end

      it "closes on Escape" do
        app.send(:handle_event, key_event(code: "esc", esc?: true))
        expect(app.view_mode_picker_active).to be false
      end

      it "pre-selects current view mode" do
        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(0)
      end

      it "pre-selects verbose when that is the current mode" do
        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@view_mode, "verbose")

        app.instance_variable_set(:@view_mode_picker_active, false)
        app.instance_variable_set(:@command_mode, true)
        app.send(:handle_event, key_event(code: "v"))

        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(1)
      end

      it "pre-selects debug when that is the current mode" do
        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@view_mode, "debug")

        app.instance_variable_set(:@view_mode_picker_active, false)
        app.instance_variable_set(:@command_mode, true)
        app.send(:handle_event, key_event(code: "v"))

        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(2)
      end

      it "moves selection down on arrow down" do
        app.send(:handle_event, key_event(code: "down"))
        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(1)
      end

      it "moves selection up on arrow up" do
        app.send(:handle_event, key_event(code: "down"))
        app.send(:handle_event, key_event(code: "up"))
        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(0)
      end

      it "clamps selection at top" do
        app.send(:handle_event, key_event(code: "up"))
        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(0)
      end

      it "clamps selection at bottom" do
        5.times { app.send(:handle_event, key_event(code: "down")) }
        expect(app.instance_variable_get(:@view_mode_picker_index)).to eq(2)
      end

      it "switches view mode on Enter" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "enter"))

        expect(chat).to have_received(:switch_view_mode).with("basic")
        expect(app.view_mode_picker_active).to be false
      end

      it "switches to verbose on Enter after moving down" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "down"))
        app.send(:handle_event, key_event(code: "enter"))

        expect(chat).to have_received(:switch_view_mode).with("verbose")
      end

      it "switches view mode on digit hotkey 1" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "1"))

        expect(chat).to have_received(:switch_view_mode).with("basic")
        expect(app.view_mode_picker_active).to be false
      end

      it "switches to verbose on digit hotkey 2" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "2"))

        expect(chat).to have_received(:switch_view_mode).with("verbose")
      end

      it "switches to debug on digit hotkey 3" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "3"))

        expect(chat).to have_received(:switch_view_mode).with("debug")
      end

      it "ignores digit hotkey beyond list size" do
        chat = app.instance_variable_get(:@screens)[:chat]
        app.send(:handle_event, key_event(code: "9"))

        expect(chat).not_to have_received(:switch_view_mode)
        expect(app.view_mode_picker_active).to be true
      end

      it "does not delegate events to chat screen while picker is active" do
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, key_event(code: "a"))

        expect(chat).not_to have_received(:handle_event)
      end
    end

    describe "token setup popup" do
      before do
        app.instance_variable_set(:@command_mode, true)
        app.send(:handle_event, key_event(code: "a"))
      end

      it "activates on Ctrl+a > a" do
        expect(app.token_setup_active).to be true
      end

      it "closes on Escape" do
        app.send(:handle_event, key_event(code: "esc", esc?: true))
        expect(app.token_setup_active).to be false
      end

      it "accepts character input" do
        app.send(:handle_event, key_event(code: "s"))
        app.send(:handle_event, key_event(code: "k"))

        buf = app.instance_variable_get(:@token_input_buffer)
        expect(buf.text).to eq("sk")
      end

      it "accepts paste input" do
        token = "sk-ant-oat01-#{"a" * 67}"
        event = double("PasteEvent", none?: false, ctrl_c?: false, paste?: true, key?: false, mouse?: false, content: token)
        app.send(:handle_event, event)

        buf = app.instance_variable_get(:@token_input_buffer)
        expect(buf.text).to eq(token)
      end

      it "submits token on Enter" do
        buf = app.instance_variable_get(:@token_input_buffer)
        buf.insert("sk-ant-oat01-#{"a" * 67}")

        app.send(:handle_event, key_event(code: "enter"))

        expect(cable_client).to have_received(:save_token).with("sk-ant-oat01-#{"a" * 67}")
        expect(app.instance_variable_get(:@token_setup_status)).to eq(:validating)
      end

      it "does not submit empty token" do
        app.send(:handle_event, key_event(code: "enter"))

        expect(cable_client).not_to have_received(:save_token)
      end

      it "supports backspace" do
        app.send(:handle_event, key_event(code: "a"))
        app.send(:handle_event, key_event(code: "b"))
        app.send(:handle_event, key_event(code: "backspace"))

        buf = app.instance_variable_get(:@token_input_buffer)
        expect(buf.text).to eq("a")
      end

      it "clears error on new input" do
        app.instance_variable_set(:@token_setup_error, "some error")
        app.instance_variable_set(:@token_setup_status, :error)

        app.send(:handle_event, key_event(code: "x"))

        expect(app.instance_variable_get(:@token_setup_error)).to be_nil
        expect(app.instance_variable_get(:@token_setup_status)).to eq(:idle)
      end

      it "ignores input during validation" do
        app.instance_variable_set(:@token_setup_status, :validating)

        app.send(:handle_event, key_event(code: "x"))

        buf = app.instance_variable_get(:@token_input_buffer)
        expect(buf.text).to eq("")
      end

      it "closes on any key in success state" do
        app.instance_variable_set(:@token_setup_status, :success)

        app.send(:handle_event, key_event(code: "enter"))

        expect(app.token_setup_active).to be false
      end

      it "does not delegate events to chat screen while active" do
        chat = app.instance_variable_get(:@screens)[:chat]
        allow(chat).to receive(:handle_event)

        app.send(:handle_event, key_event(code: "h"))

        expect(chat).not_to have_received(:handle_event)
      end

      it "ignores ctrl-modified keys" do
        key_event(code: "c", modifiers: ["ctrl"])
        # Should not insert 'c', but ctrl_c? check happens before token_setup
        # So we test a non-ctrl_c ctrl key
        event2 = key_event(code: "x", modifiers: ["ctrl"], ctrl_c?: false)
        app.send(:handle_event, event2)

        buf = app.instance_variable_get(:@token_input_buffer)
        expect(buf.text).to eq("")
      end
    end

    describe "token setup auto-activation" do
      it "activates when chat signals authentication_required" do
        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@authentication_required, true)

        app.send(:check_token_setup_signals)

        expect(app.token_setup_active).to be true
        expect(chat.authentication_required).to be false
      end

      it "does not re-activate when already active" do
        app.instance_variable_set(:@token_setup_active, true)
        app.instance_variable_set(:@token_setup_status, :validating)

        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@authentication_required, true)

        app.send(:check_token_setup_signals)

        # Should not reset status to :idle
        expect(app.instance_variable_get(:@token_setup_status)).to eq(:validating)
      end

      it "updates status to success on token_saved result" do
        app.instance_variable_set(:@token_setup_active, true)

        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@token_save_result, {success: true})

        app.send(:check_token_setup_signals)

        expect(app.instance_variable_get(:@token_setup_status)).to eq(:success)
      end

      it "updates status to error on token_error result" do
        app.instance_variable_set(:@token_setup_active, true)

        chat = app.instance_variable_get(:@screens)[:chat]
        chat.instance_variable_set(:@token_save_result, {success: false, message: "bad token"})

        app.send(:check_token_setup_signals)

        expect(app.instance_variable_get(:@token_setup_status)).to eq(:error)
        expect(app.instance_variable_get(:@token_setup_error)).to eq("bad token")
      end
    end

    describe "token masking" do
      it "returns empty string for empty input" do
        expect(app.send(:mask_token, "")).to eq("")
      end

      it "returns short text unmasked" do
        expect(app.send(:mask_token, "short")).to eq("short")
      end

      it "masks characters beyond the visible prefix" do
        token = "sk-ant-oat01-abcdefghijklmnop"
        masked = app.send(:mask_token, token)
        expect(masked).to start_with("sk-ant-oat01-a")
        expect(masked).to include("****...")
      end

      it "returns unmasked text when exactly TOKEN_MASK_VISIBLE length" do
        token = "x" * TUI::App::TOKEN_MASK_VISIBLE
        expect(app.send(:mask_token, token)).to eq(token)
      end

      it "shows exactly TOKEN_MASK_VISIBLE characters unmasked" do
        token = "sk-ant-oat01-#{"x" * 67}"
        masked = app.send(:mask_token, token)
        expect(masked[0...TUI::App::TOKEN_MASK_VISIBLE]).to eq(token[0...TUI::App::TOKEN_MASK_VISIBLE])
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

  describe "picker helpers" do
    describe "#hotkey_to_index (private)" do
      it "maps 1-9 to indices 0-8" do
        (1..9).each do |n|
          expect(app.send(:hotkey_to_index, n.to_s)).to eq(n - 1)
        end
      end

      it "maps 0 to index 9" do
        expect(app.send(:hotkey_to_index, "0")).to eq(9)
      end

      it "returns nil for non-digit keys" do
        expect(app.send(:hotkey_to_index, "a")).to be_nil
        expect(app.send(:hotkey_to_index, "esc")).to be_nil
      end
    end

    describe "#picker_hotkey (private)" do
      it "returns 1-9 for first 9 positions" do
        (0..8).each do |idx|
          expect(app.send(:picker_hotkey, idx)).to eq((idx + 1).to_s)
        end
      end

      it "returns 0 for position 9" do
        expect(app.send(:picker_hotkey, 9)).to eq("0")
      end

      it "returns nil for positions beyond 9" do
        expect(app.send(:picker_hotkey, 10)).to be_nil
      end
    end

    describe "#format_relative_time (private)" do
      it "shows 'now' for recent timestamps" do
        expect(app.send(:format_relative_time, Time.now.iso8601)).to eq("now")
      end

      it "shows minutes for timestamps within the hour" do
        time = (Time.now - 300).iso8601
        expect(app.send(:format_relative_time, time)).to eq("5m ago")
      end

      it "shows hours for timestamps within the day" do
        time = (Time.now - 7200).iso8601
        expect(app.send(:format_relative_time, time)).to eq("2h ago")
      end

      it "shows date for older timestamps" do
        time = (Time.now - 172_800).iso8601
        result = app.send(:format_relative_time, time)
        expect(result).to match(/\A\w{3} \d{2}\z/)
      end

      it "returns empty string for nil" do
        expect(app.send(:format_relative_time, nil)).to eq("")
      end
    end
  end

  describe "connection status" do
    it "defines styles for all connection states" do
      expect(TUI::App::STATUS_STYLES.keys).to contain_exactly(
        :disconnected, :connecting, :connected, :subscribed, :reconnecting
      )
    end

    it "uses emoji-only label for subscribed (normal) state" do
      expect(TUI::App::STATUS_STYLES[:subscribed][:label]).to eq("🟢")
    end

    it "uses red emoji with text for disconnected state" do
      style = TUI::App::STATUS_STYLES[:disconnected]
      expect(style[:label]).to eq("🔴 Disconnected")
      expect(style[:color]).to eq("red")
    end

    it "uses yellow emoji with text for connecting states" do
      %i[connecting connected].each do |state|
        style = TUI::App::STATUS_STYLES[state]
        expect(style[:label]).to eq("🟡 Connecting")
        expect(style[:color]).to eq("yellow")
      end
    end

    it "uses yellow emoji with text for reconnecting state" do
      style = TUI::App::STATUS_STYLES[:reconnecting]
      expect(style[:label]).to eq("🟡 Reconnecting")
      expect(style[:color]).to eq("yellow")
    end

    describe "#connection_status_line" do
      let(:tui) do
        tui = double("tui")
        allow(tui).to receive(:style) { |**kwargs| kwargs }
        allow(tui).to receive(:span) { |**kwargs| kwargs }
        allow(tui).to receive(:line) { |**kwargs| kwargs }
        tui
      end

      it "renders emoji-only for subscribed state" do
        allow(cable_client).to receive(:status).and_return(:subscribed)
        result = app.send(:connection_status_line, tui)
        span = result[:spans].first
        expect(span[:content]).to eq("🟢")
        expect(span[:style][:fg]).to eq("green")
      end

      it "renders emoji with text for disconnected state" do
        allow(cable_client).to receive(:status).and_return(:disconnected)
        result = app.send(:connection_status_line, tui)
        span = result[:spans].first
        expect(span[:content]).to eq("🔴 Disconnected")
        expect(span[:style][:fg]).to eq("red")
      end

      it "renders emoji with text for connecting state" do
        allow(cable_client).to receive(:status).and_return(:connecting)
        result = app.send(:connection_status_line, tui)
        span = result[:spans].first
        expect(span[:content]).to eq("🟡 Connecting")
        expect(span[:style][:fg]).to eq("yellow")
      end

      it "appends attempt counter for reconnecting state" do
        allow(cable_client).to receive(:status).and_return(:reconnecting)
        allow(cable_client).to receive(:reconnect_attempt).and_return(3)
        result = app.send(:connection_status_line, tui)
        span = result[:spans].first
        expect(span[:content]).to eq("🟡 Reconnecting (3/10)")
        expect(span[:style][:fg]).to eq("yellow")
      end

      it "falls back to disconnected style for unknown status" do
        allow(cable_client).to receive(:status).and_return(:unknown_state)
        result = app.send(:connection_status_line, tui)
        span = result[:spans].first
        expect(span[:content]).to eq("🔴 Disconnected")
        expect(span[:style][:fg]).to eq("red")
      end
    end
  end
end
