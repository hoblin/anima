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
      it "stores user_message events as raw payloads" do
        event = {"type" => "user_message", "content" => "hello"}
        store.process_event(event)

        expect(store.messages).to eq([event])
      end

      it "stores agent_message events as raw payloads" do
        event = {"type" => "agent_message", "content" => "hi there"}
        store.process_event(event)

        expect(store.messages).to eq([event])
      end

      it "ignores system_message events" do
        result = store.process_event({"type" => "system_message", "content" => "retrying..."})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "ignores message events with nil content" do
        result = store.process_event({"type" => "user_message", "content" => nil})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "stores message events with empty string content" do
        result = store.process_event({"type" => "user_message", "content" => ""})

        expect(result).to be true
        expect(store.messages.size).to eq(1)
      end

      it "ignores events with unknown type" do
        result = store.process_event({"type" => "unknown", "content" => "data"})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "ignores events with no type key" do
        result = store.process_event({"content" => "orphan"})

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

        expect(store.messages.map { |m| m["content"] }).to eq(%w[first second third])
      end
    end

    context "with tool events" do
      it "stores tool_call events as raw payloads" do
        event = {"type" => "tool_call", "content" => "calling bash", "tool_name" => "bash"}
        store.process_event(event)

        expect(store.messages).to eq([event])
      end

      it "stores tool_response events as raw payloads" do
        event = {"type" => "tool_response", "content" => "output", "tool_name" => "bash"}
        store.process_event(event)

        expect(store.messages).to eq([event])
      end

      it "stores consecutive tool events individually" do
        call = {"type" => "tool_call", "content" => "calling bash"}
        response = {"type" => "tool_response", "content" => "ok"}
        store.process_event(call)
        store.process_event(response)

        expect(store.messages).to eq([call, response])
      end

      it "returns true for tool_call events" do
        expect(store.process_event({"type" => "tool_call", "content" => "bash"})).to be true
      end

      it "returns true for tool_response events" do
        expect(store.process_event({"type" => "tool_response", "content" => "ok"})).to be true
      end

      it "stores tool_response without preceding tool_call" do
        event = {"type" => "tool_response", "content" => "output"}
        store.process_event(event)

        expect(store.messages).to eq([event])
      end
    end

    context "with mixed message and tool event sequences" do
      it "preserves full event sequence" do
        events = [
          {"type" => "user_message", "content" => "What's the git status?"},
          {"type" => "tool_call", "content" => "calling bash"},
          {"type" => "tool_response", "content" => "clean"},
          {"type" => "tool_call", "content" => "calling bash"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "agent_message", "content" => "Your branch is clean."}
        ]

        events.each { |e| store.process_event(e) }

        expect(store.messages).to eq(events)
      end

      it "preserves multiple conversation turns" do
        events = [
          {"type" => "user_message", "content" => "first"},
          {"type" => "tool_call", "content" => "bash"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "agent_message", "content" => "done"},
          {"type" => "user_message", "content" => "second"},
          {"type" => "tool_call", "content" => "web"},
          {"type" => "tool_response", "content" => "ok"},
          {"type" => "agent_message", "content" => "done again"}
        ]

        events.each { |e| store.process_event(e) }

        expect(store.messages).to eq(events)
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
