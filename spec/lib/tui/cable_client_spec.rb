# frozen_string_literal: true

require "spec_helper"
require "tui/cable_client"

RSpec.describe TUI::CableClient do
  let(:host) { "localhost:42134" }
  let(:session_id) { 42 }

  subject(:client) { described_class.new(host: host, session_id: session_id) }

  describe "#initialize" do
    it "starts disconnected" do
      expect(client.status).to eq(:disconnected)
    end

    it "stores the host" do
      expect(client.host).to eq(host)
    end

    it "stores the session_id" do
      expect(client.session_id).to eq(session_id)
    end

    it "defaults session_id to nil" do
      client = described_class.new(host: host)
      expect(client.session_id).to be_nil
    end

    it "starts with zero reconnect attempts" do
      expect(client.reconnect_attempt).to eq(0)
    end
  end

  describe "#drain_messages" do
    it "returns empty array when no messages" do
      expect(client.drain_messages).to eq([])
    end

    it "drains all queued messages" do
      queue = client.instance_variable_get(:@message_queue)
      queue << {"type" => "user_message", "content" => "hello"}
      queue << {"type" => "agent_message", "content" => "hi"}

      messages = client.drain_messages
      expect(messages.size).to eq(2)
      expect(messages[0]["content"]).to eq("hello")
      expect(messages[1]["content"]).to eq("hi")
    end

    it "empties the queue after draining" do
      queue = client.instance_variable_get(:@message_queue)
      queue << {"type" => "user_message", "content" => "hello"}

      client.drain_messages
      expect(client.drain_messages).to eq([])
    end
  end

  describe "#handle_protocol_message (private)" do
    it "transitions to connected on welcome" do
      client.send(:handle_protocol_message, {"type" => "welcome"})

      expect(client.status).to eq(:connected)
    end

    it "queues subscribing status before sending subscribe command on welcome" do
      client.send(:handle_protocol_message, {"type" => "welcome"})

      messages = client.drain_messages
      expect(messages.first).to eq({"type" => "connection", "status" => "subscribing"})
    end

    it "subscribes with session_id 0 when session_id is nil" do
      nil_client = described_class.new(host: host)
      nil_client.send(:handle_protocol_message, {"type" => "welcome"})

      expect(nil_client.instance_variable_get(:@subscribed_session_id)).to eq(0)
    end

    it "transitions to subscribed on confirm_subscription" do
      client.send(:handle_protocol_message, {"type" => "confirm_subscription"})

      expect(client.status).to eq(:subscribed)
      messages = client.drain_messages
      expect(messages.last).to eq({"type" => "connection", "status" => "subscribed"})
    end

    it "resets reconnect_attempt on confirm_subscription" do
      client.instance_variable_set(:@reconnect_attempt, 5)

      client.send(:handle_protocol_message, {"type" => "confirm_subscription"})

      expect(client.reconnect_attempt).to eq(0)
    end

    it "transitions to disconnected on reject_subscription" do
      client.send(:handle_protocol_message, {"type" => "reject_subscription"})

      expect(client.status).to eq(:disconnected)
      messages = client.drain_messages
      expect(messages.last).to eq({"type" => "connection", "status" => "rejected"})
    end

    it "transitions to disconnected on disconnect" do
      client.send(:handle_protocol_message, {"type" => "disconnect"})

      expect(client.status).to eq(:disconnected)
    end

    context "when server sends disconnect with reconnect: false" do
      it "sets intentional disconnect to prevent reconnection" do
        client.send(:handle_protocol_message, {"type" => "disconnect", "reconnect" => false})

        expect(client.status).to eq(:disconnected)
        expect(client.send(:intentional_disconnect?)).to be true
      end
    end

    it "updates last_ping_at on ping messages" do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      client.send(:handle_protocol_message, {"type" => "ping", "message" => 1234567890})

      expect(client.instance_variable_get(:@last_ping_at)).to eq(freeze_time)
      expect(client.drain_messages).to be_empty
    end

    it "updates last_ping_at on welcome" do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      client.send(:handle_protocol_message, {"type" => "welcome"})

      expect(client.instance_variable_get(:@last_ping_at)).to eq(freeze_time)
    end

    it "queues regular channel messages" do
      client.send(:handle_protocol_message, {
        "identifier" => '{"channel":"SessionChannel","session_id":42}',
        "message" => {"type" => "agent_message", "content" => "hello"}
      })

      messages = client.drain_messages
      expect(messages.size).to eq(1)
      expect(messages[0]).to eq({"type" => "agent_message", "content" => "hello"})
    end

    it "ignores messages without message key" do
      client.send(:handle_protocol_message, {"identifier" => "..."})

      expect(client.drain_messages).to be_empty
    end
  end

  describe "#speak" do
    let(:ws) { double("WebSocket") }

    before do
      client.instance_variable_set(:@ws, ws)
    end

    it "sends a message command with speak action" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.speak("hello brain")

      expect(sent["command"]).to eq("message")
      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("speak")
      expect(data["content"]).to eq("hello brain")
    end
  end

  describe "#create_session" do
    let(:ws) { double("WebSocket") }

    before { client.instance_variable_set(:@ws, ws) }

    it "sends a create_session action" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.create_session

      expect(sent["command"]).to eq("message")
      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("create_session")
    end
  end

  describe "#interrupt" do
    let(:ws) { double("WebSocket") }

    before { client.instance_variable_set(:@ws, ws) }

    it "sends an interrupt_execution action" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.interrupt

      expect(sent["command"]).to eq("message")
      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("interrupt_execution")
    end
  end

  describe "#switch_session" do
    let(:ws) { double("WebSocket") }

    before { client.instance_variable_set(:@ws, ws) }

    it "sends a switch_session action with session_id" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.switch_session(99)

      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("switch_session")
      expect(data["session_id"]).to eq(99)
    end
  end

  describe "#list_sessions" do
    let(:ws) { double("WebSocket") }

    before { client.instance_variable_set(:@ws, ws) }

    it "sends a list_sessions action with limit" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.list_sessions(limit: 5)

      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("list_sessions")
      expect(data["limit"]).to eq(5)
    end

    it "defaults to limit of 10" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.list_sessions

      data = JSON.parse(sent["data"])
      expect(data["limit"]).to eq(10)
    end
  end

  describe "#change_view_mode" do
    let(:ws) { double("WebSocket") }

    before { client.instance_variable_set(:@ws, ws) }

    it "sends a change_view_mode action with view_mode" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.change_view_mode("verbose")

      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("change_view_mode")
      expect(data["view_mode"]).to eq("verbose")
    end
  end

  describe "#save_token" do
    let(:ws) { double("WebSocket") }

    before { client.instance_variable_set(:@ws, ws) }

    it "sends a save_token action with the token" do
      sent = nil
      allow(ws).to receive(:send) { |msg| sent = JSON.parse(msg) }

      client.save_token("sk-ant-oat01-test-token-value")

      data = JSON.parse(sent["data"])
      expect(data["action"]).to eq("save_token")
      expect(data["token"]).to eq("sk-ant-oat01-test-token-value")
    end
  end

  describe "#update_session_id" do
    it "updates the session_id" do
      client.update_session_id(99)
      expect(client.session_id).to eq(99)
    end
  end

  describe "#disconnect" do
    it "sets intentional disconnect flag" do
      client.disconnect
      expect(client.send(:intentional_disconnect?)).to be true
    end

    it "transitions to disconnected" do
      client.disconnect
      expect(client.status).to eq(:disconnected)
    end
  end

  describe "reconnection" do
    describe "#on_disconnected (private)" do
      it "transitions to disconnected and queues message" do
        client.instance_variable_set(:@status, :subscribed)

        client.send(:on_disconnected)

        expect(client.status).to eq(:disconnected)
        messages = client.drain_messages
        expect(messages.last).to eq({"type" => "connection", "status" => "disconnected"})
      end

      it "does not transition if already disconnected" do
        client.instance_variable_set(:@status, :disconnected)

        client.send(:on_disconnected)

        expect(client.drain_messages).to be_empty
      end

      it "does not transition if already reconnecting" do
        client.instance_variable_set(:@status, :reconnecting)

        client.send(:on_disconnected)

        expect(client.status).to eq(:reconnecting)
        expect(client.drain_messages).to be_empty
      end
    end

    describe "#schedule_reconnect (private)" do
      before do
        # Stub sleep to avoid actual delays
        allow(client).to receive(:sleep)
      end

      it "increments reconnect_attempt" do
        client.send(:schedule_reconnect)

        expect(client.reconnect_attempt).to eq(1)
      end

      it "transitions to reconnecting" do
        client.send(:schedule_reconnect)

        messages = client.drain_messages
        reconnecting = messages.find { |m| m["status"] == "reconnecting" }
        expect(reconnecting).to include("attempt" => 1, "max_attempts" => 10)
      end

      it "returns true to continue reconnection loop" do
        result = client.send(:schedule_reconnect)

        expect(result).to be true
      end

      it "returns false after max attempts" do
        client.instance_variable_set(:@reconnect_attempt, described_class::MAX_RECONNECT_ATTEMPTS)

        result = client.send(:schedule_reconnect)

        expect(result).to be false
        messages = client.drain_messages
        expect(messages.last["status"]).to eq("failed")
      end

      it "returns false when intentional disconnect during backoff" do
        allow(client).to receive(:sleep) do
          client.instance_variable_set(:@intentional_disconnect, true)
        end

        result = client.send(:schedule_reconnect)

        expect(result).to be false
      end
    end

    describe "#backoff_delay (private)" do
      it "returns a value between 0 and base for attempt 1" do
        delay = client.send(:backoff_delay, 1)
        expect(delay).to be_between(0.0, described_class::BACKOFF_BASE)
      end

      it "returns a value up to 2^(attempt-1) * base" do
        max_for_attempt_5 = described_class::BACKOFF_BASE * (2**4) # 16.0
        delay = client.send(:backoff_delay, 5)
        expect(delay).to be_between(0.0, max_for_attempt_5)
      end

      it "caps delay at BACKOFF_CAP" do
        delay = client.send(:backoff_delay, 100)
        expect(delay).to be <= described_class::BACKOFF_CAP
      end
    end

    describe "#check_stale_connection (private)" do
      it "does nothing when last_ping_at is nil" do
        client.instance_variable_set(:@status, :subscribed)

        client.send(:check_stale_connection)

        expect(client.status).to eq(:subscribed)
      end

      it "does nothing when within threshold" do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        client.instance_variable_set(:@status, :subscribed)
        client.instance_variable_set(:@last_ping_at, freeze_time)

        client.send(:check_stale_connection)

        expect(client.status).to eq(:subscribed)
      end

      it "disconnects when ping is stale" do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        client.instance_variable_set(:@status, :subscribed)
        client.instance_variable_set(:@last_ping_at,
          freeze_time - described_class::PING_STALE_THRESHOLD - 1)

        client.send(:check_stale_connection)

        expect(client.status).to eq(:disconnected)
      end

      it "only checks when subscribed" do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        client.instance_variable_set(:@status, :connected)
        client.instance_variable_set(:@last_ping_at,
          freeze_time - described_class::PING_STALE_THRESHOLD - 1)

        client.send(:check_stale_connection)

        expect(client.status).to eq(:connected)
      end
    end

    describe "#stale_generation? (private)" do
      it "returns false for current generation" do
        generation = client.instance_variable_get(:@connection_generation)

        expect(client.send(:stale_generation?, generation)).to be false
      end

      it "returns true for outdated generation" do
        old_generation = client.instance_variable_get(:@connection_generation)
        client.instance_variable_set(:@connection_generation, old_generation + 1)

        expect(client.send(:stale_generation?, old_generation)).to be true
      end
    end
  end
end
