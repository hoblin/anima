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

  describe "#size" do
    it "starts at zero" do
      expect(store.size).to eq(0)
    end

    it "reflects the number of stored entries" do
      store.process_event({"type" => "user_message", "content" => "hi"})
      store.process_event({"type" => "user_message", "content" => "there"})
      expect(store.size).to eq(2)
    end

    it "decreases when entries are removed" do
      store.process_event({"type" => "user_message", "id" => 1, "content" => "hi"})
      store.remove_by_id(1)
      expect(store.size).to eq(0)
    end
  end

  describe "#process_event" do
    context "with structured decorator data" do
      it "stores structured data when present" do
        store.process_event({"type" => "user_message", "content" => "hello",
                             "rendered" => {"basic" => {"role" => "user", "content" => "hello"}}})

        expect(store.messages).to contain_exactly(
          a_hash_including(type: :rendered, data: {"role" => "user", "content" => "hello"}, message_type: "user_message")
        )
      end

      it "uses rendered content from any mode key" do
        store.process_event({"type" => "agent_message", "content" => "hi",
                             "rendered" => {"verbose" => {"role" => "assistant", "content" => "hi", "timestamp" => 123}}})

        expect(store.messages).to contain_exactly(
          a_hash_including(type: :rendered, data: {"role" => "assistant", "content" => "hi", "timestamp" => 123}, message_type: "agent_message")
        )
      end

      it "falls back to tool counter when rendered is nil for tool events" do
        store.process_event({"type" => "tool_call", "content" => "calling bash",
                             "rendered" => {"basic" => nil}})

        expect(store.messages).to eq([{type: :tool_counter, calls: 1, responses: 0}])
      end

      it "stores structured data when non-nil for tool events" do
        store.process_event({"type" => "tool_call", "content" => "calling bash",
                             "rendered" => {"verbose" => {"role" => "tool_call", "tool" => "bash", "input" => "$ ls -la"}}})

        expect(store.messages).to contain_exactly(
          a_hash_including(type: :rendered, data: {"role" => "tool_call", "tool" => "bash", "input" => "$ ls -la"}, message_type: "tool_call")
        )
      end

      it "returns true for rendered events" do
        result = store.process_event({"type" => "user_message", "content" => "hi",
                                      "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
        expect(result).to be true
      end

      it "stores the event ID when present" do
        store.process_event({"type" => "user_message", "content" => "hi", "id" => 42,
                             "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})

        expect(store.messages.first[:id]).to eq(42)
      end
    end

    context "with message events" do
      it "stores user_message events with typed entry when no rendered content" do
        store.process_event({"type" => "user_message", "content" => "hello"})

        expect(store.messages).to contain_exactly(
          a_hash_including(type: :message, role: "user", content: "hello")
        )
      end

      it "stores agent_message events with typed entry when no rendered content" do
        store.process_event({"type" => "agent_message", "content" => "hi there"})

        expect(store.messages).to contain_exactly(
          a_hash_including(type: :message, role: "assistant", content: "hi there")
        )
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

      it "stores the event ID when present" do
        store.process_event({"type" => "user_message", "content" => "hi", "id" => 99})

        expect(store.messages.first[:id]).to eq(99)
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

      it "returns false for tool_response without preceding tool_call" do
        result = store.process_event({"type" => "tool_response", "content" => "output"})

        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "handles multiple orphaned tool_responses without error" do
        store.process_event({"type" => "tool_response", "content" => "output1"})
        store.process_event({"type" => "tool_response", "content" => "output2"})

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

        expect(store.messages).to match([
          a_hash_including(type: :message, role: "user", content: "What's the git status?"),
          {type: :tool_counter, calls: 2, responses: 2},
          a_hash_including(type: :message, role: "assistant", content: "Your branch is clean.")
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

    context "with update events" do
      it "replaces rendered data for an existing entry by ID" do
        store.process_event({"type" => "user_message", "id" => 42, "action" => "create",
                             "rendered" => {"debug" => {"role" => "user", "content" => "hi", "tokens" => 5, "estimated" => true}}})

        store.process_event({"type" => "user_message", "id" => 42, "action" => "update",
                             "rendered" => {"debug" => {"role" => "user", "content" => "hi", "tokens" => 12, "estimated" => false}}})

        expect(store.messages.size).to eq(1)
        expect(store.messages.first[:data]).to include("tokens" => 12, "estimated" => false)
      end

      it "preserves entry order when updating" do
        store.process_event({"type" => "user_message", "id" => 1, "action" => "create",
                             "rendered" => {"basic" => {"role" => "user", "content" => "first"}}})
        store.process_event({"type" => "agent_message", "id" => 2, "action" => "create",
                             "rendered" => {"basic" => {"role" => "assistant", "content" => "second"}}})

        store.process_event({"type" => "user_message", "id" => 1, "action" => "update",
                             "rendered" => {"basic" => {"role" => "user", "content" => "first (updated)"}}})

        contents = store.messages.map { |m| m[:data]["content"] }
        expect(contents).to eq(["first (updated)", "second"])
      end

      it "returns false when updating a non-existent ID" do
        result = store.process_event({"type" => "user_message", "id" => 999, "action" => "update",
                                      "rendered" => {"basic" => {"role" => "user", "content" => "nope"}}})
        expect(result).to be false
        expect(store.messages).to be_empty
      end

      it "returns false when update has no rendered data" do
        store.process_event({"type" => "user_message", "id" => 42, "action" => "create",
                             "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})

        result = store.process_event({"type" => "user_message", "id" => 42, "action" => "update",
                                      "content" => "only content, no rendered"})
        expect(result).to be false
      end

      it "does not duplicate entries on update" do
        store.process_event({"type" => "user_message", "id" => 42, "action" => "create",
                             "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
        store.process_event({"type" => "user_message", "id" => 42, "action" => "update",
                             "rendered" => {"basic" => {"role" => "user", "content" => "hi (v2)"}}})
        store.process_event({"type" => "user_message", "id" => 42, "action" => "update",
                             "rendered" => {"basic" => {"role" => "user", "content" => "hi (v3)"}}})

        expect(store.messages.size).to eq(1)
        expect(store.messages.first[:data]["content"]).to eq("hi (v3)")
      end
    end

    context "with out-of-order event arrival" do
      it "sorts rendered entries by event ID regardless of arrival order" do
        store.process_event({"type" => "agent_message", "id" => 3,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "third"}}})
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "first"}}})
        store.process_event({"type" => "tool_call", "id" => 2,
                             "rendered" => {"debug" => {"role" => "tool_call", "content" => "second"}}})

        contents = store.messages.map { |m| m[:data]["content"] }
        expect(contents).to eq(%w[first second third])
      end

      it "places system prompt at position 0 even when it arrives after other events" do
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "hello"}}})
        store.process_event({"type" => "agent_message", "id" => 2,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "hi"}}})
        store.process_event({"id" => 0, "type" => "system_prompt",
                             "rendered" => {"debug" => {"role" => "system_prompt", "content" => "You are..."}}})

        entries = store.messages
        expect(entries.first[:data]["role"]).to eq("system_prompt")
        expect(entries.map { |m| m[:data]["content"] }).to eq(["You are...", "hello", "hi"])
      end

      it "updates system prompt in-place when a new one arrives" do
        store.process_event({"id" => 0, "type" => "system_prompt",
                             "rendered" => {"debug" => {"role" => "system_prompt", "content" => "v1"}}})
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "hello"}}})
        store.process_event({"id" => 0, "type" => "system_prompt",
                             "rendered" => {"debug" => {"role" => "system_prompt", "content" => "v2"}}})

        entries = store.messages
        system_prompts = entries.select { |e| e[:message_type] == "system_prompt" }
        expect(system_prompts.size).to eq(1)
        expect(entries.first[:data]["content"]).to eq("v2")
      end

      it "appends in-order events without scanning (fast path)" do
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "first"}}})
        store.process_event({"type" => "agent_message", "id" => 2,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "second"}}})
        store.process_event({"type" => "user_message", "id" => 3,
                             "rendered" => {"debug" => {"role" => "user", "content" => "third"}}})

        contents = store.messages.map { |m| m[:data]["content"] }
        expect(contents).to eq(%w[first second third])
      end

      it "prepends descending-order events without scanning (session history replay)" do
        store.process_event({"type" => "user_message", "id" => 5,
                             "rendered" => {"debug" => {"role" => "user", "content" => "fifth"}}})
        store.process_event({"type" => "agent_message", "id" => 4,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "fourth"}}})
        store.process_event({"type" => "user_message", "id" => 3,
                             "rendered" => {"debug" => {"role" => "user", "content" => "third"}}})
        store.process_event({"type" => "agent_message", "id" => 2,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "second"}}})
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "first"}}})

        contents = store.messages.map { |m| m[:data]["content"] }
        expect(contents).to eq(%w[first second third fourth fifth])
      end

      it "handles a single out-of-order event in a large sequence" do
        (1..5).each do |i|
          next if i == 3
          store.process_event({"type" => "user_message", "id" => i,
                               "rendered" => {"debug" => {"role" => "user", "content" => "msg#{i}"}}})
        end
        # Event 3 arrives last
        store.process_event({"type" => "user_message", "id" => 3,
                             "rendered" => {"debug" => {"role" => "user", "content" => "msg3"}}})

        contents = store.messages.map { |m| m[:data]["content"] }
        expect(contents).to eq(%w[msg1 msg2 msg3 msg4 msg5])
      end

      it "preserves non-ID entries alongside ID-sorted entries" do
        store.process_event({"type" => "tool_call", "content" => "bash"})
        store.process_event({"type" => "user_message", "id" => 2,
                             "rendered" => {"debug" => {"role" => "user", "content" => "second"}}})
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "first"}}})

        entries = store.messages
        expect(entries[0][:type]).to eq(:tool_counter)
        expect(entries[1][:data]["content"]).to eq("first")
        expect(entries[2][:data]["content"]).to eq("second")
      end

      it "deduplicates events with the same ID" do
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "original"}}})
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "duplicate"}}})

        expect(store.size).to eq(1)
        expect(store.messages.first[:data]["content"]).to eq("duplicate")
      end

      it "handles viewport replay after a live event (view mode switch race)" do
        store.process_event({"type" => "agent_message", "id" => 100,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "live"}}})
        store.process_event({"type" => "user_message", "id" => 1,
                             "rendered" => {"debug" => {"role" => "user", "content" => "first"}}})
        store.process_event({"type" => "agent_message", "id" => 2,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "second"}}})
        store.process_event({"type" => "user_message", "id" => 50,
                             "rendered" => {"debug" => {"role" => "user", "content" => "middle"}}})
        store.process_event({"type" => "agent_message", "id" => 100,
                             "rendered" => {"debug" => {"role" => "assistant", "content" => "replayed"}}})

        ids = store.messages.map { |m| m[:id] }
        expect(ids).to eq([1, 2, 50, 100])
        expect(store.size).to eq(4)
        expect(store.messages.last[:data]["content"]).to eq("replayed")
      end

      it "orders plain message events by ID" do
        store.process_event({"type" => "user_message", "id" => 3, "content" => "third"})
        store.process_event({"type" => "user_message", "id" => 1, "content" => "first"})
        store.process_event({"type" => "agent_message", "id" => 2, "content" => "second"})

        expect(store.messages.map { |m| m[:id] }).to eq([1, 2, 3])
      end
    end
  end

  describe "#clear" do
    it "removes all entries and clears the ID index" do
      store.process_event({"type" => "user_message", "content" => "hi", "id" => 42,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
      store.process_event({"type" => "tool_call", "content" => "bash"})
      store.clear
      expect(store.messages).to be_empty

      result = store.process_event({"type" => "user_message", "id" => 42, "action" => "update",
                                    "rendered" => {"basic" => {"role" => "user", "content" => "updated"}}})
      expect(result).to be false
    end
  end

  describe "#add_pending / #remove_pending / #last_pending_user_message" do
    it "adds a pending entry that appears after real messages" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "first"}}})
      store.add_pending(42, "waiting")

      msgs = store.messages
      expect(msgs.size).to eq(2)
      expect(msgs.last.dig(:data, "status")).to eq("pending")
      expect(msgs.last.dig(:data, "content")).to eq("waiting")
    end

    it "returns the last pending user message" do
      store.add_pending(42, "pending msg")

      result = store.last_pending_user_message
      expect(result).to eq({pending_message_id: 42, content: "pending msg"})
    end

    it "returns nil when no pending messages exist" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "delivered"}}})

      expect(store.last_pending_user_message).to be_nil
    end

    it "returns nil when store is empty" do
      expect(store.last_pending_user_message).to be_nil
    end

    it "removes a pending entry by pending_message_id" do
      store.add_pending(42, "will remove")
      expect(store.remove_pending(42)).to be true
      expect(store.messages.size).to eq(0)
    end

    it "returns false when pending_message_id not found" do
      expect(store.remove_pending(999)).to be false
    end

    it "clears pending entries on clear" do
      store.add_pending(42, "pending")
      store.clear
      expect(store.last_pending_user_message).to be_nil
    end
  end

  describe "#remove_by_id" do
    it "removes an entry by event ID" do
      store.process_event({"type" => "user_message", "id" => 42,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})

      expect(store.remove_by_id(42)).to be true
      expect(store.messages).to be_empty
    end

    it "returns false for non-existent ID" do
      expect(store.remove_by_id(999)).to be false
    end

    it "clears the ID index so updates to removed entries are ignored" do
      store.process_event({"type" => "user_message", "id" => 42,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
      store.remove_by_id(42)

      result = store.process_event({"type" => "user_message", "id" => 42, "action" => "update",
                                    "rendered" => {"basic" => {"role" => "user", "content" => "updated"}}})
      expect(result).to be false
      expect(store.messages).to be_empty
    end
  end

  describe "#remove_above" do
    it "removes entries with id <= cutoff" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "first"}}})
      store.process_event({"type" => "agent_message", "id" => 2,
                           "rendered" => {"basic" => {"role" => "assistant", "content" => "second"}}})
      store.process_event({"type" => "user_message", "id" => 3,
                           "rendered" => {"basic" => {"role" => "user", "content" => "third"}}})

      store.remove_above(2)
      expect(store.messages.size).to eq(1)
      expect(store.messages.first[:id]).to eq(3)
    end

    it "returns count of removed entries" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "first"}}})
      store.process_event({"type" => "agent_message", "id" => 2,
                           "rendered" => {"basic" => {"role" => "assistant", "content" => "second"}}})
      store.process_event({"type" => "user_message", "id" => 3,
                           "rendered" => {"basic" => {"role" => "user", "content" => "third"}}})

      expect(store.remove_above(2)).to eq(2)
    end

    it "returns zero when no entries match" do
      store.process_event({"type" => "user_message", "id" => 10,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})

      expect(store.remove_above(5)).to eq(0)
      expect(store.messages.size).to eq(1)
    end

    it "clears ID index so updates to removed entries are ignored" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
      store.remove_above(1)

      result = store.process_event({"type" => "user_message", "id" => 1, "action" => "update",
                                    "rendered" => {"basic" => {"role" => "user", "content" => "updated"}}})
      expect(result).to be false
      expect(store.messages).to be_empty
    end

    it "increments version when entries are removed" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
      expect { store.remove_above(1) }.to change { store.version }.by(1)
    end

    it "does not increment version when no entries match" do
      expect { store.remove_above(999) }.not_to change { store.version }
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

  describe "#version" do
    it "starts at zero" do
      expect(store.version).to eq(0)
    end

    it "increments when a message is added" do
      expect { store.process_event({"type" => "user_message", "content" => "hi"}) }
        .to change { store.version }.by(1)
    end

    it "increments when a rendered event is added" do
      expect {
        store.process_event({"type" => "user_message", "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
      }.to change { store.version }.by(1)
    end

    it "increments on tool call and tool response" do
      expect { store.process_event({"type" => "tool_call", "content" => "bash"}) }
        .to change { store.version }.by(1)

      expect { store.process_event({"type" => "tool_response", "content" => "ok"}) }
        .to change { store.version }.by(1)
    end

    it "does not increment on tool_response without a preceding tool_call" do
      expect { store.process_event({"type" => "tool_response", "content" => "ok"}) }
        .not_to change { store.version }
    end

    it "increments on clear" do
      store.process_event({"type" => "user_message", "content" => "hi"})
      expect { store.clear }.to change { store.version }.by(1)
    end

    it "increments on remove_by_id" do
      store.process_event({"type" => "user_message", "id" => 1, "content" => "hi"})
      expect { store.remove_by_id(1) }.to change { store.version }.by(1)
    end

    it "does not increment on failed remove_by_id" do
      expect { store.remove_by_id(999) }.not_to change { store.version }
    end

    it "increments on remove_above when entries are removed" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "hi"}}})
      expect { store.remove_above(1) }.to change { store.version }.by(1)
    end

    it "does not increment on remove_above when no entries match" do
      expect { store.remove_above(999) }.not_to change { store.version }
    end

    it "increments on update_existing" do
      store.process_event({"type" => "user_message", "id" => 1,
                           "rendered" => {"basic" => {"role" => "user", "content" => "v1"}}})

      expect {
        store.process_event({"type" => "user_message", "id" => 1, "action" => "update",
                             "rendered" => {"basic" => {"role" => "user", "content" => "v2"}}})
      }.to change { store.version }.by(1)
    end

    it "is monotonically increasing across multiple operations" do
      versions = []
      versions << store.version
      store.process_event({"type" => "user_message", "content" => "first"})
      versions << store.version
      store.process_event({"type" => "tool_call", "content" => "bash"})
      versions << store.version
      store.process_event({"type" => "tool_response", "content" => "ok"})
      versions << store.version
      store.clear
      versions << store.version

      expect(versions).to eq(versions.sort)
      expect(versions.uniq.size).to eq(versions.size)
    end
  end

  describe "#token_economy" do
    it "returns empty stats when no messages have api_metrics" do
      stats = store.token_economy

      expect(stats[:input_tokens]).to eq(0)
      expect(stats[:output_tokens]).to eq(0)
      expect(stats[:cache_read_input_tokens]).to eq(0)
      expect(stats[:cache_creation_input_tokens]).to eq(0)
      expect(stats[:call_count]).to eq(0)
      expect(stats[:cache_hit_rate]).to eq(0.0)
      expect(stats[:rate_limits]).to be_nil
    end

    it "accumulates token counts from api_metrics" do
      store.process_event({
        "type" => "agent_message",
        "content" => "Hello",
        "api_metrics" => {
          "usage" => {
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cache_read_input_tokens" => 80,
            "cache_creation_input_tokens" => 20
          }
        }
      })

      stats = store.token_economy
      expect(stats[:input_tokens]).to eq(100)
      expect(stats[:output_tokens]).to eq(50)
      expect(stats[:cache_read_input_tokens]).to eq(80)
      expect(stats[:cache_creation_input_tokens]).to eq(20)
      expect(stats[:call_count]).to eq(1)
    end

    it "accumulates across multiple messages" do
      2.times do
        store.process_event({
          "type" => "agent_message",
          "content" => "msg",
          "api_metrics" => {
            "usage" => {"input_tokens" => 50, "output_tokens" => 25}
          }
        })
      end

      stats = store.token_economy
      expect(stats[:input_tokens]).to eq(100)
      expect(stats[:output_tokens]).to eq(50)
      expect(stats[:call_count]).to eq(2)
    end

    it "calculates cache hit rate correctly" do
      store.process_event({
        "type" => "agent_message",
        "content" => "msg",
        "api_metrics" => {
          "usage" => {
            "input_tokens" => 20,
            "cache_read_input_tokens" => 80,
            "cache_creation_input_tokens" => 0
          }
        }
      })

      stats = store.token_economy
      expect(stats[:cache_hit_rate]).to eq(0.8)
    end

    it "stores the most recent rate_limits" do
      store.process_event({
        "type" => "agent_message",
        "content" => "first",
        "api_metrics" => {
          "rate_limits" => {"5h_utilization" => 0.20},
          "usage" => {"input_tokens" => 10}
        }
      })
      store.process_event({
        "type" => "agent_message",
        "content" => "second",
        "api_metrics" => {
          "rate_limits" => {"5h_utilization" => 0.25},
          "usage" => {"input_tokens" => 10}
        }
      })

      stats = store.token_economy
      expect(stats[:rate_limits]["5h_utilization"]).to eq(0.25)
    end

    it "does not accumulate metrics on update actions" do
      store.process_event({
        "type" => "agent_message",
        "id" => 1,
        "content" => "msg",
        "api_metrics" => {"usage" => {"input_tokens" => 50}}
      })
      store.process_event({
        "type" => "agent_message",
        "id" => 1,
        "action" => "update",
        "content" => "updated",
        "api_metrics" => {"usage" => {"input_tokens" => 50}}
      })

      expect(store.token_economy[:input_tokens]).to eq(50)
      expect(store.token_economy[:call_count]).to eq(1)
    end

    it "resets token_economy on clear" do
      store.process_event({
        "type" => "agent_message",
        "content" => "msg",
        "api_metrics" => {
          "usage" => {"input_tokens" => 100},
          "rate_limits" => {"5h_utilization" => 0.5}
        }
      })

      store.clear

      stats = store.token_economy
      expect(stats[:input_tokens]).to eq(0)
      expect(stats[:call_count]).to eq(0)
      expect(stats[:rate_limits]).to be_nil
    end

    it "caps cache_history at MAX_CACHE_HISTORY entries" do
      (TUI::Settings.message_store_max_cache_history + 10).times do |i|
        store.process_event({
          "type" => "agent_message",
          "content" => "msg #{i}",
          "api_metrics" => {
            "usage" => {"input_tokens" => 50, "cache_read_input_tokens" => 50}
          }
        })
      end

      stats = store.token_economy
      expect(stats[:cache_history].size).to eq(TUI::Settings.message_store_max_cache_history)
    end

    it "handles missing or malformed api_metrics gracefully" do
      store.process_event({"type" => "agent_message", "content" => "no metrics"})
      store.process_event({"type" => "agent_message", "content" => "bad", "api_metrics" => "not a hash"})
      store.process_event({"type" => "agent_message", "content" => "empty", "api_metrics" => {}})

      expect(store.token_economy[:call_count]).to eq(0)
    end
  end
end
