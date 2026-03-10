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
    it "stores user_message events" do
      store.process_event({"type" => "user_message", "content" => "hello"})

      expect(store.messages).to eq([{role: "user", content: "hello"}])
    end

    it "stores agent_message events" do
      store.process_event({"type" => "agent_message", "content" => "hi there"})

      expect(store.messages).to eq([{role: "assistant", content: "hi there"}])
    end

    it "ignores system_message events" do
      result = store.process_event({"type" => "system_message", "content" => "retrying..."})

      expect(result).to be false
      expect(store.messages).to be_empty
    end

    it "ignores tool_call events" do
      result = store.process_event({"type" => "tool_call", "content" => "running bash"})

      expect(result).to be false
      expect(store.messages).to be_empty
    end

    it "ignores tool_response events" do
      result = store.process_event({"type" => "tool_response", "content" => "output"})

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

  describe "#clear" do
    it "removes all messages" do
      store.process_event({"type" => "user_message", "content" => "hi"})
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
