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

    it "transitions to subscribed on confirm_subscription" do
      client.send(:handle_protocol_message, {"type" => "confirm_subscription"})

      expect(client.status).to eq(:subscribed)
      messages = client.drain_messages
      expect(messages.last).to eq({"type" => "connection", "status" => "subscribed"})
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

    it "ignores ping messages" do
      client.send(:handle_protocol_message, {"type" => "ping", "message" => 1234567890})

      expect(client.drain_messages).to be_empty
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

  describe "#resubscribe" do
    let(:ws) { double("WebSocket", send: nil, close: nil) }

    before do
      client.instance_variable_set(:@ws, ws)
    end

    it "updates session_id" do
      client.resubscribe(99)
      expect(client.session_id).to eq(99)
    end

    it "sends unsubscribe for old session and subscribe for new" do
      sent_messages = []
      allow(ws).to receive(:send) { |msg| sent_messages << JSON.parse(msg) }

      client.resubscribe(99)

      expect(sent_messages.size).to eq(2)
      expect(sent_messages[0]["command"]).to eq("unsubscribe")
      expect(JSON.parse(sent_messages[0]["identifier"])["session_id"]).to eq(42)
      expect(sent_messages[1]["command"]).to eq("subscribe")
      expect(JSON.parse(sent_messages[1]["identifier"])["session_id"]).to eq(99)
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

  describe "#update_session_id" do
    it "updates the session_id" do
      client.update_session_id(99)
      expect(client.session_id).to eq(99)
    end
  end
end
