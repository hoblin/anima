# frozen_string_literal: true

require "spec_helper"
require "tui/message_store"

RSpec.describe TUI::MessageStore do
  subject(:store) { described_class.new }

  describe "#messages" do
    it "starts empty" do
      expect(store.messages).to eq([])
    end

    it "returns a copy (not the internal array)" do
      store.process_event({"type" => "user_message", "content" => "hi"})
      messages = store.messages
      messages.clear
      expect(store.messages.size).to eq(1)
    end
  end

  describe "#process_event" do
    context "with message events" do
      it "stores user_message events with typed entry" do
        store.process_event({"type" => "user_message", "content" => "hello"})

        expect(store.messages).to eq([{type: :message, role: "user", content: "hello"}])
      end

      it "stores agent_message events with typed entry" do
        store.process_event({"type" => "agent_message", "content" => "hi there"})

        expect(store.messages).to eq([{type: :message, role: "assistant", content: "hi there"}])
      end

      it "ignores system_message events" do
        result = store.process_event({"type" => "system_message", "content" => "retrying..."})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "ignores events with nil content" do
        result = store.process_event({"type" => "user_message", "content" => nil})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "ignores events with unknown type" do
        result = store.process_event({"type" => "unknown", "content" => "data"})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "returns true for stored events" do
        expect(store.process_event({"type" => "user_message", "content" => "hi"})).to be true
      end

      it "preserves message order" do
        store.process_event({"type" => "user_message", "content" => "first"})
        store.process_event({"type" => "agent_message", "content" => "second"})
        store.process_event({"type" => "user_message", "content" => "third"})

        expect(store.messages.map { |m| m[:content] }).to eq(%w[first second third])
      end
    end

    context "with tool events" do
      it "creates a tool_counter entry on first tool_call" do
        store.process_event({"type" => "tool_call", "content" => "calling bash"})

        expect(store.messages).to eq([{type: :tool_counter, calls: 1, responses: 0}])
      end

      it "increments calls on consecutive tool_call events" do
        store.process_event({"type" => "tool_call", "content" => "calling bash"})
        store.process_event({"type" => "tool_call", "content" => "calling web_get"})

        expect(store.messages).to eq([{type: :tool_counter, calls: 2, responses: 0}])
      end

      it "increments responses on tool_response" do
        store.process_event({"type" => "tool_call", "content" => "calling bash"})
        store.process_event({"type" => "tool_response", "content" => "output"})

        expect(store.messages).to eq([{type: :tool_counter, calls: 1, responses: 1}])
      end

      it "tracks interleaved tool_call and tool_response events" do
        store.process_event({"type" => "tool_call", "content" => "calling bash"})
        store.process_event({"type" => "tool_response", "content" => "output1"})
        store.process_event({"type" => "tool_call", "content" => "calling web_get"})
        store.process_event({"type" => "tool_response", "content" => "output2"})

        expect(store.messages).to eq([{type: :tool_counter, calls: 2, responses: 2}])
      end

      it "returns true for tool_call events" do
        expect(store.process_event({"type" => "tool_call", "content" => "calling bash"})).to be true
      end

      it "returns true for tool_response events" do
        store.process_event({"type" => "tool_call", "content" => "calling bash"})
        expect(store.process_event({"type" => "tool_response", "content" => "output"})).to be true
      end

      it "ignores tool_response without preceding tool_counter" do
        result = store.process_event({"type" => "tool_response", "content" => "output"})

        expect(result).to be true
        expect(store.messages).to be_empty
      end
    end

    context "with mixed message and tool event sequences" do
      it "interlaces messages and tool counters" do
        store.process_event({"type" => "user_message", "content" => "What's the git status?"})
        store.process_event({"type" => "tool_call", "content" => "calling bash"})
        store.process_event({"type" => "tool_response", "content" => "clean"})
        store.process_event({"type" => "tool_call", "content" => "calling bash"})
        store.process_event({"type" => "tool_response", "content" => "ok"})
        store.process_event({"type" => "agent_message", "content" => "Your branch is clean."})

        expect(store.messages).to eq([
          {type: :message, role: "user", content: "What's the git status?"},
          {type: :tool_counter, calls: 2, responses: 2},
          {type: :message, role: "assistant", content: "Your branch is clean."}
        ])
      end

      it "creates separate counters for multiple tool chains" do
        store.process_event({"type" => "user_message", "content" => "first"})
        store.process_event({"type" => "tool_call", "content" => "bash"})
        store.process_event({"type" => "tool_response", "content" => "ok"})
        store.process_event({"type" => "agent_message", "content" => "done"})
        store.process_event({"type" => "user_message", "content" => "second"})
        store.process_event({"type" => "tool_call", "content" => "web"})
        store.process_event({"type" => "tool_response", "content" => "ok"})
        store.process_event({"type" => "agent_message", "content" => "done again"})

        counters = store.messages.select { |e| e[:type] == :tool_counter }
        expect(counters.size).to eq(2)
        expect(counters).to all(include(calls: 1, responses: 1))
      end
    end
  end

  describe "#clear" do
    it "removes all entries" do
      store.process_event({"type" => "user_message", "content" => "hi"})
      store.process_event({"type" => "tool_call", "content" => "bash"})
      store.clear
      expect(store.messages).to be_empty
    end
  end

  describe "thread safety" do
    it "handles concurrent writes without errors" do
      threads = 10.times.map do |i|
        Thread.new do
          store.process_event({"type" => "user_message", "content" => "msg #{i}"})
        end
      end
      threads.each(&:join)

      expect(store.messages.size).to eq(10)
    end
  end
end
