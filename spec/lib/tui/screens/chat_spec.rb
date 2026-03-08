# frozen_string_literal: true

require "rails_helper"
require "ratatui_ruby"

RSpec.describe TUI::Screens::Chat do
  subject(:screen) { described_class.new }

  # RatatuiRuby::Event uses method_missing for dynamic predicates,
  # so we use plain doubles instead of instance_double
  def key_event(code:, modifiers: nil, **overrides)
    defaults = {
      key?: true, enter?: false, backspace?: false, esc?: false,
      none?: false, ctrl_c?: false
    }
    defaults[:enter?] = true if code == "enter"
    defaults[:backspace?] = true if code == "backspace"
    defaults[:esc?] = true if code == "esc"
    double("Event", **defaults, code: code, modifiers: modifiers, **overrides)
  end

  after { Events::Bus.unsubscribe(screen.message_collector) }

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

    it "subscribes the message collector to the event bus" do
      screen # force lazy subject to initialize and subscribe
      Events::Bus.emit(Events::UserMessage.new(content: "test"))
      expect(screen.messages).to eq([{role: "user", content: "test"}])
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

      before do
        screen.instance_variable_set(:@client, client)
        allow(client).to receive(:chat).and_return("Hello back!")
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
        allow(client).to receive(:chat) do
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
        expect(client).not_to have_received(:chat)
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

      before do
        screen.instance_variable_set(:@client, client)
        allow(client).to receive(:chat).and_raise(StandardError, "Connection failed")
      end

      it "emits error as agent_message event" do
        screen.handle_event(key_event(code: "h"))
        screen.handle_event(key_event(code: "i"))
        screen.handle_event(key_event(code: "enter"))

        sleep 0.1

        expect(screen.messages.last).to eq({role: "assistant", content: "Error: Connection failed"})
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
      let(:client) { double("LLM::Client") }

      before do
        screen.instance_variable_set(:@client, client)
      end

      it "passes full message history to LLM client" do
        received_messages = nil
        allow(client).to receive(:chat).and_return("First response")
        screen.handle_event(key_event(code: "a"))
        screen.handle_event(key_event(code: "enter"))
        sleep 0.1

        allow(client).to receive(:chat) { |msgs|
          received_messages = msgs.dup
          "Second response"
        }
        screen.handle_event(key_event(code: "b"))
        screen.handle_event(key_event(code: "enter"))
        sleep 0.1

        expect(received_messages).to eq([
          {role: "user", content: "a"},
          {role: "assistant", content: "First response"},
          {role: "user", content: "b"}
        ])
      end
    end

    context "unrecognized keys" do
      it "returns false for arrow keys" do
        event = key_event(code: "up", up?: true)
        expect(screen.handle_event(event)).to be false
      end
    end
  end

  describe "#new_session" do
    let(:client) { double("LLM::Client") }

    before do
      screen.instance_variable_set(:@client, client)
      allow(client).to receive(:chat).and_return("response")

      screen.handle_event(key_event(code: "h"))
      screen.handle_event(key_event(code: "i"))
      screen.handle_event(key_event(code: "enter"))
      sleep 0.1
    end

    it "clears messages" do
      screen.new_session
      expect(screen.messages).to eq([])
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
  end

  describe "#finalize" do
    it "unsubscribes the message collector from the event bus" do
      screen.finalize
      Events::Bus.emit(Events::UserMessage.new(content: "after finalize"))
      expect(screen.messages).to be_empty
    end
  end
end
