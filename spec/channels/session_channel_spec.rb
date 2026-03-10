# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionChannel, type: :channel do
  let(:session_id) { 42 }
  let(:stream_name) { "session_#{session_id}" }

  describe "#subscribed" do
    it "streams from the session-specific stream" do
      subscribe(session_id: session_id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(stream_name)
    end

    it "works with string session_id" do
      subscribe(session_id: "7")

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("session_7")
    end

    it "rejects subscription without session_id" do
      subscribe(session_id: nil)

      expect(subscription).to be_rejected
    end

    it "rejects subscription with non-numeric session_id" do
      subscribe(session_id: "abc")

      expect(subscription).to be_rejected
    end

    it "rejects subscription with zero session_id" do
      subscribe(session_id: 0)

      expect(subscription).to be_rejected
    end

    it "transmits chat history for existing session" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi there"}, timestamp: 2)
      session.events.create!(event_type: "tool_call", payload: {"type" => "tool_call", "content" => "calling bash"}, timestamp: 3)

      subscribe(session_id: session_id)

      expect(transmissions.size).to eq(2)
      expect(transmissions[0]).to include("type" => "user_message", "content" => "hello")
      expect(transmissions[1]).to include("type" => "agent_message", "content" => "hi there")
    end

    it "transmits no history for a session with no messages" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      expect(transmissions).to be_empty
    end
  end

  describe "#receive" do
    it "broadcasts the received data to the session stream" do
      subscribe(session_id: session_id)
      data = {"type" => "user_message", "content" => "hello"}

      expect { perform(:receive, data) }
        .to have_broadcasted_to(stream_name).with(hash_including(data))
    end
  end

  describe "#speak" do
    let!(:session) { Session.create!(id: session_id) }

    before { subscribe(session_id: session_id) }

    it "emits a user_message event on the EventBus" do
      emitted = []
      subscriber = double("subscriber")
      allow(subscriber).to receive(:emit) { |event| emitted << event }
      Events::Bus.subscribe(subscriber)

      perform(:speak, {"content" => "hello brain"})

      user_event = emitted.find { |e| e.dig(:payload, :type) == "user_message" }
      expect(user_event).to be_present
      expect(user_event.dig(:payload, :content)).to eq("hello brain")
      expect(user_event.dig(:payload, :session_id)).to eq(session_id)

      Events::Bus.unsubscribe(subscriber)
    end

    it "enqueues an AgentRequestJob" do
      expect { perform(:speak, {"content" => "process this"}) }
        .to have_enqueued_job(AgentRequestJob).with(session_id)
    end

    it "ignores empty content" do
      expect { perform(:speak, {"content" => "  "}) }
        .not_to have_enqueued_job(AgentRequestJob)
    end

    it "ignores nil content" do
      expect { perform(:speak, {"content" => nil}) }
        .not_to have_enqueued_job(AgentRequestJob)
    end

    it "strips whitespace from content" do
      emitted = []
      subscriber = double("subscriber")
      allow(subscriber).to receive(:emit) { |event| emitted << event }
      Events::Bus.subscribe(subscriber)

      perform(:speak, {"content" => "  hello  "})

      user_event = emitted.find { |e| e.dig(:payload, :type) == "user_message" }
      expect(user_event.dig(:payload, :content)).to eq("hello")

      Events::Bus.unsubscribe(subscriber)
    end
  end

  describe "stream isolation" do
    it "does not broadcast to other sessions" do
      subscribe(session_id: session_id)
      data = {"type" => "user_message", "content" => "hello"}

      expect { perform(:receive, data) }
        .not_to have_broadcasted_to("session_99")
    end
  end
end
