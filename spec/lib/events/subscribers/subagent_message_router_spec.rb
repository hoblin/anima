# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::SubagentMessageRouter do
  subject(:router) { described_class.new }

  describe "child → parent routing" do
    let(:parent) { Session.create! }
    let(:child) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "loop-sleuth") }

    context "when parent is idle" do
      it "persists an attributed user_message in the parent session" do
        event = Events::AgentMessage.new(content: "Here's my analysis.", session_id: child.id)
        router.emit(name: event.event_name, payload: event.to_h)

        parent_msg = parent.events.find_by(event_type: "user_message")
        expect(parent_msg).to be_present
        expect(parent_msg.payload["content"]).to include("loop-sleuth")
        expect(parent_msg.payload["content"]).to include("Here's my analysis.")
      end

      it "uses attribution format with @name prefix" do
        event = Events::AgentMessage.new(content: "Done!", session_id: child.id)
        router.emit(name: event.event_name, payload: event.to_h)

        parent_msg = parent.events.find_by(event_type: "user_message")
        expect(parent_msg.payload["content"]).to eq("[sub-agent @loop-sleuth]: Done!")
      end

      it "enqueues AgentRequestJob for the parent session" do
        event = Events::AgentMessage.new(content: "Result ready.", session_id: child.id)
        router.emit(name: event.event_name, payload: event.to_h)

        expect(AgentRequestJob).to have_been_enqueued.with(parent.id)
      end

      it "falls back to agent-N when child has no name" do
        unnamed = Session.create!(parent_session: parent, prompt: "sub-agent")

        event = Events::AgentMessage.new(content: "Result", session_id: unnamed.id)
        router.emit(name: event.event_name, payload: event.to_h)

        parent_msg = parent.events.find_by(event_type: "user_message")
        expect(parent_msg.payload["content"]).to start_with("[sub-agent @agent-#{unnamed.id}]:")
      end
    end

    context "when parent is processing" do
      before { parent.update!(processing: true) }

      it "emits a pending user_message via EventBus" do
        emitted = []
        subscriber = double("subscriber")
        allow(subscriber).to receive(:emit) { |event| emitted << event }
        Events::Bus.subscribe(subscriber)

        event = Events::AgentMessage.new(content: "Here's my analysis.", session_id: child.id)
        router.emit(name: event.event_name, payload: event.to_h)

        user_event = emitted.find { |e| e.dig(:payload, :type) == "user_message" }
        expect(user_event).to be_present
        expect(user_event.dig(:payload, :status)).to eq(Event::PENDING_STATUS)
        expect(user_event.dig(:payload, :content)).to include("[sub-agent @loop-sleuth]:")
        expect(user_event.dig(:payload, :content)).to include("Here's my analysis.")
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "does not enqueue AgentRequestJob" do
        event = Events::AgentMessage.new(content: "Result ready.", session_id: child.id)
        router.emit(name: event.event_name, payload: event.to_h)

        expect(AgentRequestJob).not_to have_been_enqueued
      end

      it "does not persist a deliverable event directly" do
        event = Events::AgentMessage.new(content: "Result ready.", session_id: child.id)
        router.emit(name: event.event_name, payload: event.to_h)

        expect(parent.events.where(event_type: "user_message", status: nil).count).to eq(0)
      end
    end

    it "ignores non-agent_message events" do
      event = Events::UserMessage.new(content: "hi", session_id: child.id)
      router.emit(name: event.event_name, payload: event.to_h)

      expect(parent.events.where(event_type: "user_message").count).to eq(0)
    end

    it "ignores events with empty content" do
      event = Events::AgentMessage.new(content: "", session_id: child.id)
      router.emit(name: event.event_name, payload: event.to_h)

      expect(parent.events.where(event_type: "user_message").count).to eq(0)
    end

    it "ignores events with missing session" do
      event = Events::AgentMessage.new(content: "hello", session_id: -1)
      expect { router.emit(name: event.event_name, payload: event.to_h) }.not_to raise_error
    end
  end

  describe "parent → child routing (@mentions)" do
    let(:parent) { Session.create! }
    let!(:child_a) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "loop-sleuth") }
    let!(:child_b) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "api-scout") }

    it "routes @mention to the matching child session" do
      event = Events::AgentMessage.new(
        content: "@loop-sleuth Check the edit tool next.",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      child_msg = child_a.events.find_by(event_type: "user_message")
      expect(child_msg).to be_present
      expect(child_msg.payload["content"]).to include("Check the edit tool next.")
    end

    it "routes to multiple mentioned children" do
      event = Events::AgentMessage.new(
        content: "@loop-sleuth finish up, @api-scout start searching",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(child_a.events.where(event_type: "user_message").count).to eq(1)
      expect(child_b.events.where(event_type: "user_message").count).to eq(1)
    end

    it "enqueues AgentRequestJob for each mentioned child" do
      event = Events::AgentMessage.new(
        content: "@loop-sleuth here's context, @api-scout check this",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(AgentRequestJob).to have_been_enqueued.with(child_a.id)
      expect(AgentRequestJob).to have_been_enqueued.with(child_b.id)
    end

    it "ignores @mentions that don't match any child" do
      event = Events::AgentMessage.new(
        content: "@unknown-agent do something",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(child_a.events.where(event_type: "user_message").count).to eq(0)
      expect(child_b.events.where(event_type: "user_message").count).to eq(0)
    end

    it "does not route when message has no @mentions" do
      event = Events::AgentMessage.new(
        content: "I'll think about it and get back to you.",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(child_a.events.where(event_type: "user_message").count).to eq(0)
    end

    it "does not route to children without names" do
      unnamed = Session.create!(parent_session: parent, prompt: "sub-agent")

      event = Events::AgentMessage.new(
        content: "hey @#{unnamed.id} do something",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(unnamed.events.where(event_type: "user_message").count).to eq(0)
    end
  end
end
